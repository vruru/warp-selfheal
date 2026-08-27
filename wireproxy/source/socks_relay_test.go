package wireproxy

import (
	"io"
	"net"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/things-go/go-socks5"
)

func TestSocksRelayReclaimsHalfClosedConnections(t *testing.T) {
	var heldMu sync.Mutex
	var held []net.Conn
	target := listenTCP(t)
	defer target.Close()
	go func() {
		for {
			conn, err := target.Accept()
			if err != nil {
				return
			}
			go func() {
				_, _ = io.Copy(io.Discard, conn)
				heldMu.Lock()
				held = append(held, conn)
				heldMu.Unlock()
			}()
		}
	}()

	proxy := listenTCP(t)
	defer proxy.Close()
	server := socks5.NewServer(socks5.WithConnectHandle(newSocks5ConnectHandler((&net.Dialer{}).DialContext, 25*time.Millisecond)))
	go func() { _ = server.Serve(proxy) }()

	baseline := runtime.NumGoroutine()
	for i := 0; i < 200; i++ {
		conn := socksConnect(t, proxy.Addr().String(), target.Addr().(*net.TCPAddr))
		_ = conn.Close()
	}

	time.Sleep(250 * time.Millisecond)
	runtime.GC()
	if got := runtime.NumGoroutine(); got > baseline+30 {
		t.Fatalf("orphaned SOCKS goroutines were not reclaimed: baseline=%d final=%d", baseline, got)
	}

	heldMu.Lock()
	defer heldMu.Unlock()
	for _, conn := range held {
		_ = conn.Close()
	}
}

func TestSocksRelayKeepsActiveHalfClosedResponse(t *testing.T) {
	target := listenTCP(t)
	defer target.Close()
	go func() {
		conn, err := target.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(io.Discard, conn)
		for i := 0; i < 5; i++ {
			_, _ = conn.Write([]byte{'x'})
			time.Sleep(15 * time.Millisecond)
		}
	}()

	proxy := listenTCP(t)
	defer proxy.Close()
	server := socks5.NewServer(socks5.WithConnectHandle(newSocks5ConnectHandler((&net.Dialer{}).DialContext, 100*time.Millisecond)))
	go func() { _ = server.Serve(proxy) }()

	conn := socksConnect(t, proxy.Addr().String(), target.Addr().(*net.TCPAddr))
	defer conn.Close()
	if err := conn.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 5)
	if _, err := io.ReadFull(conn, response); err != nil {
		t.Fatalf("active half-closed response was interrupted: %v", err)
	}
}

func listenTCP(t *testing.T) *net.TCPListener {
	t.Helper()
	listener, err := net.ListenTCP("tcp", &net.TCPAddr{IP: net.ParseIP("127.0.0.1")})
	if err != nil {
		t.Fatal(err)
	}
	return listener
}

func socksConnect(t *testing.T, proxy string, target *net.TCPAddr) *net.TCPConn {
	t.Helper()
	conn, err := net.DialTCP("tcp", nil, mustResolveTCP(t, proxy))
	if err != nil {
		t.Fatal(err)
	}
	port := target.Port
	request := []byte{5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, byte(port >> 8), byte(port)}
	if _, err := conn.Write(request); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 12)
	if _, err := io.ReadFull(conn, response); err != nil {
		t.Fatal(err)
	}
	if response[3] != 0 {
		t.Fatalf("SOCKS connect failed: %v", response)
	}
	return conn
}

func mustResolveTCP(t *testing.T, address string) *net.TCPAddr {
	t.Helper()
	addr, err := net.ResolveTCPAddr("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	return addr
}
