package airplay

import (
	"context"
	"net"
	"syscall"
	"time"
)

// soRecvAnyIf is macOS's SO_RECV_ANYIF. Apple TVs reached by peer-to-peer
// AirPlay ("Direct Connect", the awdl0 interface) sit on a restricted
// interface: macOS drops incoming packets there for any socket that hasn't
// opted in, so a TCP connect times out and UDP replies vanish. Setting this
// on every socket lets those receivers work. Elsewhere the call just fails
// and is ignored.
const soRecvAnyIf = 0x1104

func anyIfControl(network, address string, c syscall.RawConn) error {
	_ = c.Control(func(fd uintptr) {
		_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, soRecvAnyIf, 1)
	})
	return nil
}

func dialTCP(address string, timeout time.Duration) (net.Conn, error) {
	d := net.Dialer{Timeout: timeout, Control: anyIfControl}
	return d.Dial("tcp", address)
}

func listenPacket(network, address string) (net.PacketConn, error) {
	lc := net.ListenConfig{Control: anyIfControl}
	return lc.ListenPacket(context.Background(), network, address)
}
