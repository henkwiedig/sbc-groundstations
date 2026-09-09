/*
 * Small standalone link-status tool for the AR8030 baseband link, added by
 * this project (not part of upstream yz_host_drv) -- upstream ships a
 * pairing tool (bb_pair) and an AT-style firmware debug console (cmd_dbg),
 * but nothing that answers "is the link actually up and passing data".
 *
 * Uses the same libar8030_client API bb_pair does (bb_host_connect ->
 * bb_dev_getlist -> bb_dev_open), then polls two things once a second:
 *
 *  - BB_GET_STATUS: link_status[] per slot -- link_state IDLE/LOCK/CONNECT
 *    (CONNECT means the DATA channel, not just the control channel, is
 *    locked with the peer) plus which peer MAC and rx_mcs.
 *  - BB_GET_PEER_QUALITY: bb_quality_t per slot on the *data* channel --
 *    snr and, importantly, ldpc_err/ldpc_num. A nonzero and growing
 *    ldpc_num over time is the actual proof real frames are being
 *    received and decoded, not just that pairing/link-lock succeeded.
 *    (BB_GET_STATUS's per-slot bb_phy_status_t is config/parameters only
 *    -- mcs, bandwidth, freq_khz -- it carries no quality numbers.)
 *  - BB_GET_SOCK_INFO (port=-1, i.e. all sockets of the slot): per-port,
 *    per-direction (BB_DIR_TX/BB_DIR_RX) cumulative byte counters
 *    (bb_sock_uni_t.total_size) and overflow_cnt -- actual application
 *    data volume moved, distinct from the physical-layer LDPC block
 *    counts above.
 */
#include "ar8030.h"
#include "bb_api.h"
#include "bb_dev.h"
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int g_run = 1;

static void on_sigint(int sig)
{
    (void)sig;
    g_run = 0;
}

static const char* link_state_name(uint8_t state)
{
    switch (state) {
    case BB_LINK_STATE_IDLE:
        return "IDLE";
    case BB_LINK_STATE_LOCK:
        return "LOCK (control channel only)";
    case BB_LINK_STATE_CONNECT:
        return "CONNECT (data channel up)";
    default:
        return "UNKNOWN";
    }
}

int main(int argc, char* argv[])
{
    const char* ip   = "127.0.0.1";
    int         port = BB_PORT_DEFAULT;
    int         once = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") || !strcmp(argv[i], "--once")) {
            once = 1;
        } else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: %s [-o|--once]\n"
                   "  -o, --once   print one snapshot and exit (default: poll once/sec until Ctrl-C)\n",
                   argv[0]);
            return 0;
        }
    }

    signal(SIGINT, on_sigint);

    bb_host_t* phost = NULL;
    int        ret   = bb_host_connect(&phost, ip, port);
    if (ret) {
        fprintf(stderr, "connect to daemon failed (ret=%d) -- is ar8030-daemon running?\n", ret);
        return 1;
    }

    bb_dev_t** devs;
    int        dev_cnt = bb_dev_getlist(phost, &devs);
    if (dev_cnt <= 0) {
        fprintf(stderr, "no AR8030 device known to the daemon\n");
        bb_host_disconnect(phost);
        return 1;
    }

    bb_dev_handle_t* hbb = bb_dev_open(devs[0]);
    if (!hbb) {
        fprintf(stderr, "bb_dev_open failed\n");
        bb_dev_freelist(devs);
        bb_host_disconnect(phost);
        return 1;
    }

    do {
        bb_get_status_in_t  st_in  = { .user_bmp = 0xffff };
        bb_get_status_out_t st_out;
        memset(&st_out, 0, sizeof(st_out));
        ret = bb_ioctl(hbb, BB_GET_STATUS, &st_in, &st_out);
        if (ret) {
            fprintf(stderr, "BB_GET_STATUS failed (ret=%d)\n", ret);
            break;
        }

        bb_get_peer_quality_in_t  pq_in  = { .slot_bmp = 0xff, .arverage = 0 };
        bb_get_peer_quality_out_t pq_out;
        memset(&pq_out, 0, sizeof(pq_out));
        ret = bb_ioctl(hbb, BB_GET_PEER_QUALITY, &pq_in, &pq_out);
        if (ret) {
            fprintf(stderr, "BB_GET_PEER_QUALITY failed (ret=%d)\n", ret);
            break;
        }

        /*
         * role/mode/mac/cfg_sbmp/rt_sbmp read as all-zero on every poll
         * observed on real hardware regardless of actual link state --
         * this daemon/firmware build evidently doesn't populate
         * BB_GET_STATUS's top-level self-info fields at all in this mode.
         * Printed for visibility but NOT trustworthy for anything,
         * including (as tried and reverted) using rt_sbmp to decide which
         * slots are active.
         */
        printf("role=%u mode=%u mac=%02x:%02x:%02x:%02x cfg_sbmp=0x%02x rt_sbmp=0x%02x\n", st_out.role,
               st_out.mode, st_out.mac.addr[0], st_out.mac.addr[1], st_out.mac.addr[2], st_out.mac.addr[3],
               st_out.cfg_sbmp, st_out.rt_sbmp);

        /*
         * What actually distinguishes a real slot from uninitialized
         * memory: link_status[s].state is a bb_link_state_e (0/1/2, see
         * BB_LINK_STATE_MAX) -- garbage slots observed on real hardware
         * had state=98 and state=216, both nonsense outside that range.
         * Require a valid enum value, and either CONNECT or a nonzero
         * peer_mac (so a genuinely-IDLE-but-tracked slot isn't hidden).
         */
        for (int s = 0; s < BB_SLOT_MAX; s++) {
            bb_link_status_t* ls = &st_out.link_status[s];
            bb_quality_t*      q  = &pq_out.qualities[s];
            int                valid_state = ls->state < BB_LINK_STATE_MAX;
            int                slot_seen = valid_state && (ls->state != BB_LINK_STATE_IDLE || ls->peer_mac.addr[0] ||
                                            ls->peer_mac.addr[1] || ls->peer_mac.addr[2] || ls->peer_mac.addr[3]);
            if (!slot_seen) {
                continue;
            }
            double snr_db = q->snr > 0 ? 10.0 * log10((double)q->snr / 36.0) : 0.0;
            printf("  slot %d: %-28s peer=%02x:%02x:%02x:%02x rx_mcs=%u\n", s, link_state_name(ls->state),
                   ls->peer_mac.addr[0], ls->peer_mac.addr[1], ls->peer_mac.addr[2], ls->peer_mac.addr[3],
                   ls->rx_mcs);
            printf("    peer data-channel quality: snr=%u (%.1f dB) ldpc=%u/%u gain_a=%u gain_b=%u\n", q->snr,
                   snr_db, q->ldpc_err, q->ldpc_num, q->gain_a, q->gain_b);

            bb_get_sock_info_in_t  si_in  = { .slot = (uint8_t)s, .port = -1 };
            bb_get_sock_info_out_t si_out;
            memset(&si_out, 0, sizeof(si_out));
            if (bb_ioctl(hbb, BB_GET_SOCK_INFO, &si_in, &si_out)) {
                continue; /* not fatal -- keep showing link/quality even if this fails */
            }
            for (int p = 0; p < BB_SOCK_INFO_NUM; p++) {
                bb_sock_uni_t* tx = &si_out.sock_info[p].uni_info[BB_DIR_TX];
                bb_sock_uni_t* rx = &si_out.sock_info[p].uni_info[BB_DIR_RX];
                if (!tx->available && !rx->available) {
                    continue; /* port not in use */
                }
                printf("    port %d: tx_bytes=%llu (overflow=%u) rx_bytes=%llu (overflow=%u)\n", p,
                       (unsigned long long)tx->total_size, tx->overflow_cnt, (unsigned long long)rx->total_size,
                       rx->overflow_cnt);
            }
        }

        fflush(stdout);
        if (once) {
            break;
        }
        sleep(1);
    } while (g_run);

    bb_dev_close(hbb);
    bb_dev_freelist(devs);
    bb_host_disconnect(phost);

    return 0;
}
