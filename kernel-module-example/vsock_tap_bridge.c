/*
 * vsock_tap_bridge.c - Kernel module for bridging vsock and TAP interfaces
 *
 * This is a realistic example of what a kernel module would look like for Arca.
 * It creates a TAP device and bridges packets between vsock and TAP in kernel space.
 *
 * Estimated lines of code: ~500-800 LOC for production-ready version
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/skbuff.h>
#include <linux/if_arp.h>
#include <linux/kthread.h>
#include <linux/sched.h>
#include <net/sock.h>
#include <linux/virtio_vsock.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Arca Project");
MODULE_DESCRIPTION("vsock-TAP bridge for container networking");
MODULE_VERSION("1.0");

/* Module parameters (passed via insmod/modprobe) */
static unsigned int vsock_port = 5000;
module_param(vsock_port, uint, 0444);
MODULE_PARM_DESC(vsock_port, "vsock port to listen on");

static char *tap_name = "tap0";
module_param(tap_name, charp, 0444);
MODULE_PARM_DESC(tap_name, "TAP device name");

static char *ip_addr = "172.18.0.2";
module_param(ip_addr, charp, 0444);
MODULE_PARM_DESC(ip_addr, "IP address to assign");

/* Global state */
struct vsock_tap_bridge {
    struct net_device *tap_dev;      /* TAP network device */
    struct socket *vsock_sock;       /* vsock socket */
    struct task_struct *rx_thread;   /* Receive thread */
    struct task_struct *tx_thread;   /* Transmit thread */
    struct sk_buff_head rx_queue;    /* Receive packet queue */
    struct sk_buff_head tx_queue;    /* Transmit packet queue */
    bool running;                    /* Module running flag */
};

static struct vsock_tap_bridge *bridge = NULL;

/*
 * TAP device transmit function
 * Called when the network stack wants to send a packet out the TAP device
 */
static netdev_tx_t tap_xmit(struct sk_buff *skb, struct net_device *dev)
{
    if (!bridge || !bridge->running) {
        dev_kfree_skb(skb);
        return NETDEV_TX_OK;
    }

    /* Queue packet for vsock transmission */
    skb_queue_tail(&bridge->tx_queue, skb);

    /* Wake up transmit thread */
    wake_up_process(bridge->tx_thread);

    return NETDEV_TX_OK;
}

/*
 * TAP device operations
 */
static const struct net_device_ops tap_netdev_ops = {
    .ndo_start_xmit = tap_xmit,
};

/*
 * Setup TAP device
 */
static void tap_setup(struct net_device *dev)
{
    ether_setup(dev);  /* Setup as Ethernet device */

    dev->netdev_ops = &tap_netdev_ops;
    dev->flags |= IFF_NOARP;
    dev->flags &= ~IFF_MULTICAST;

    /* Generate random MAC address */
    eth_hw_addr_random(dev);
}

/*
 * Receive thread - reads from vsock and injects into TAP device
 * This runs continuously in kernel space
 */
static int vsock_rx_thread(void *data)
{
    struct vsock_tap_bridge *br = data;
    struct msghdr msg;
    struct kvec iov;
    unsigned char buffer[65536];
    int len;
    struct sk_buff *skb;

    pr_info("vsock_tap_bridge: RX thread started\n");

    while (!kthread_should_stop() && br->running) {
        /* Setup message structure for kernel_recvmsg */
        memset(&msg, 0, sizeof(msg));
        iov.iov_base = buffer;
        iov.iov_len = sizeof(buffer);

        /* Receive packet from vsock (blocking) */
        len = kernel_recvmsg(br->vsock_sock, &msg, &iov, 1, sizeof(buffer), 0);

        if (len <= 0) {
            if (len == -EAGAIN)
                continue;
            pr_err("vsock_tap_bridge: recvmsg error: %d\n", len);
            break;
        }

        /* Allocate sk_buff (socket buffer - kernel's packet structure) */
        skb = dev_alloc_skb(len + 2);
        if (!skb) {
            pr_err("vsock_tap_bridge: failed to allocate skb\n");
            continue;
        }

        skb_reserve(skb, 2);  /* Align IP header */
        memcpy(skb_put(skb, len), buffer, len);

        /* Set up skb for injection into network stack */
        skb->dev = br->tap_dev;
        skb->protocol = eth_type_trans(skb, br->tap_dev);
        skb->ip_summed = CHECKSUM_UNNECESSARY;

        /* Inject packet into network stack */
        netif_rx(skb);

        /* Update statistics */
        br->tap_dev->stats.rx_packets++;
        br->tap_dev->stats.rx_bytes += len;
    }

    pr_info("vsock_tap_bridge: RX thread stopped\n");
    return 0;
}

/*
 * Transmit thread - reads from TAP device queue and sends via vsock
 */
static int vsock_tx_thread(void *data)
{
    struct vsock_tap_bridge *br = data;
    struct sk_buff *skb;
    struct msghdr msg;
    struct kvec iov;
    int len;

    pr_info("vsock_tap_bridge: TX thread started\n");

    while (!kthread_should_stop() && br->running) {
        /* Wait for packet in queue */
        skb = skb_dequeue(&br->tx_queue);
        if (!skb) {
            /* No packets, sleep */
            set_current_state(TASK_INTERRUPTIBLE);
            schedule_timeout(HZ / 100);  /* 10ms timeout */
            continue;
        }

        /* Setup message for kernel_sendmsg */
        memset(&msg, 0, sizeof(msg));
        iov.iov_base = skb->data;
        iov.iov_len = skb->len;

        /* Send packet via vsock */
        len = kernel_sendmsg(br->vsock_sock, &msg, &iov, 1, skb->len);

        if (len < 0) {
            pr_err("vsock_tap_bridge: sendmsg error: %d\n", len);
        } else {
            /* Update statistics */
            br->tap_dev->stats.tx_packets++;
            br->tap_dev->stats.tx_bytes += len;
        }

        /* Free the socket buffer */
        dev_kfree_skb(skb);
    }

    pr_info("vsock_tap_bridge: TX thread stopped\n");
    return 0;
}

/*
 * Module initialization
 */
static int __init vsock_tap_bridge_init(void)
{
    int ret;
    struct sockaddr_vm addr;

    pr_info("vsock_tap_bridge: Initializing (vsock_port=%u, tap=%s, ip=%s)\n",
            vsock_port, tap_name, ip_addr);

    /* Allocate bridge structure */
    bridge = kzalloc(sizeof(*bridge), GFP_KERNEL);
    if (!bridge)
        return -ENOMEM;

    /* Initialize packet queues */
    skb_queue_head_init(&bridge->rx_queue);
    skb_queue_head_init(&bridge->tx_queue);
    bridge->running = true;

    /* Create TAP device */
    bridge->tap_dev = alloc_netdev(0, tap_name, NET_NAME_UNKNOWN, tap_setup);
    if (!bridge->tap_dev) {
        pr_err("vsock_tap_bridge: failed to allocate TAP device\n");
        ret = -ENOMEM;
        goto err_free_bridge;
    }

    /* Register TAP device with network stack */
    ret = register_netdev(bridge->tap_dev);
    if (ret) {
        pr_err("vsock_tap_bridge: failed to register TAP device: %d\n", ret);
        goto err_free_netdev;
    }

    /* Create vsock socket */
    ret = sock_create_kern(&init_net, AF_VSOCK, SOCK_STREAM, 0, &bridge->vsock_sock);
    if (ret) {
        pr_err("vsock_tap_bridge: failed to create vsock socket: %d\n", ret);
        goto err_unregister_netdev;
    }

    /* Connect to vsock host (CID 2 = host) */
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_HOST;  /* 2 = host */
    addr.svm_port = vsock_port;

    ret = kernel_connect(bridge->vsock_sock, (struct sockaddr *)&addr,
                        sizeof(addr), 0);
    if (ret) {
        pr_err("vsock_tap_bridge: failed to connect vsock: %d\n", ret);
        goto err_close_socket;
    }

    /* Start receive thread */
    bridge->rx_thread = kthread_run(vsock_rx_thread, bridge, "vsock_rx");
    if (IS_ERR(bridge->rx_thread)) {
        ret = PTR_ERR(bridge->rx_thread);
        pr_err("vsock_tap_bridge: failed to start RX thread: %d\n", ret);
        goto err_close_socket;
    }

    /* Start transmit thread */
    bridge->tx_thread = kthread_run(vsock_tx_thread, bridge, "vsock_tx");
    if (IS_ERR(bridge->tx_thread)) {
        ret = PTR_ERR(bridge->tx_thread);
        pr_err("vsock_tap_bridge: failed to start TX thread: %d\n", ret);
        goto err_stop_rx;
    }

    /* Bring TAP device up */
    rtnl_lock();
    dev_open(bridge->tap_dev, NULL);
    rtnl_unlock();

    pr_info("vsock_tap_bridge: Successfully initialized\n");
    return 0;

err_stop_rx:
    kthread_stop(bridge->rx_thread);
err_close_socket:
    sock_release(bridge->vsock_sock);
err_unregister_netdev:
    unregister_netdev(bridge->tap_dev);
err_free_netdev:
    free_netdev(bridge->tap_dev);
err_free_bridge:
    kfree(bridge);
    bridge = NULL;
    return ret;
}

/*
 * Module cleanup
 */
static void __exit vsock_tap_bridge_exit(void)
{
    pr_info("vsock_tap_bridge: Cleaning up\n");

    if (!bridge)
        return;

    /* Signal threads to stop */
    bridge->running = false;

    /* Stop threads */
    if (bridge->tx_thread)
        kthread_stop(bridge->tx_thread);
    if (bridge->rx_thread)
        kthread_stop(bridge->rx_thread);

    /* Close socket */
    if (bridge->vsock_sock)
        sock_release(bridge->vsock_sock);

    /* Unregister and free TAP device */
    if (bridge->tap_dev) {
        rtnl_lock();
        dev_close(bridge->tap_dev);
        rtnl_unlock();
        unregister_netdev(bridge->tap_dev);
        free_netdev(bridge->tap_dev);
    }

    /* Purge any remaining packets */
    skb_queue_purge(&bridge->rx_queue);
    skb_queue_purge(&bridge->tx_queue);

    /* Free bridge structure */
    kfree(bridge);
    bridge = NULL;

    pr_info("vsock_tap_bridge: Cleanup complete\n");
}

module_init(vsock_tap_bridge_init);
module_exit(vsock_tap_bridge_exit);
