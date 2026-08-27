package wireproxy

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/things-go/go-socks5"
	"github.com/things-go/go-socks5/statute"
)

const socksDrainIdleTimeout = 2 * time.Minute

type socksRelayResult struct {
	err error
}

type activityReader struct {
	reader       io.Reader
	lastActivity *atomic.Int64
}

func (r activityReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		r.lastActivity.Store(time.Now().UnixNano())
	}
	return n, err
}

type closeWriter interface {
	CloseWrite() error
}

func newSocks5ConnectHandler(
	dial func(context.Context, string, string) (net.Conn, error),
	drainIdleTimeout time.Duration,
) func(context.Context, io.Writer, *socks5.Request) error {
	return func(ctx context.Context, writer io.Writer, request *socks5.Request) error {
		client, ok := writer.(net.Conn)
		if !ok {
			_ = socks5.SendReply(writer, statute.RepServerFailure, nil)
			return errors.New("SOCKS writer is not a network connection")
		}

		target, err := dial(ctx, "tcp", request.DestAddr.String())
		if err != nil {
			reply := statute.RepHostUnreachable
			message := err.Error()
			switch {
			case strings.Contains(message, "refused"):
				reply = statute.RepConnectionRefused
			case strings.Contains(message, "network is unreachable"):
				reply = statute.RepNetworkUnreachable
			}
			if replyErr := socks5.SendReply(writer, reply, nil); replyErr != nil {
				return fmt.Errorf("failed to send SOCKS reply: %w", replyErr)
			}
			return fmt.Errorf("connect to %v failed: %w", request.RawDestAddr, err)
		}
		defer target.Close()

		if err := socks5.SendReply(writer, statute.RepSuccess, target.LocalAddr()); err != nil {
			return fmt.Errorf("failed to send SOCKS success reply: %w", err)
		}

		return relaySocksConnection(client, request.Reader, target, drainIdleTimeout)
	}
}

func relaySocksConnection(client net.Conn, clientReader io.Reader, target net.Conn, drainIdleTimeout time.Duration) error {
	if drainIdleTimeout <= 0 {
		return errors.New("SOCKS drain idle timeout must be positive")
	}

	var lastActivity atomic.Int64
	lastActivity.Store(time.Now().UnixNano())
	results := make(chan socksRelayResult, 2)

	copyDirection := func(dst io.Writer, src io.Reader) {
		_, err := io.CopyBuffer(dst, activityReader{reader: src, lastActivity: &lastActivity}, make([]byte, 32*1024))
		if halfCloser, ok := dst.(closeWriter); ok {
			_ = halfCloser.CloseWrite()
		}
		results <- socksRelayResult{err: err}
	}

	go copyDirection(target, clientReader)
	go copyDirection(client, target)

	first := <-results
	if first.err != nil && !errors.Is(first.err, net.ErrClosed) {
		_ = client.Close()
		_ = target.Close()
		<-results
		return first.err
	}

	// One TCP direction can legitimately half-close while the opposite direction
	// keeps transferring a response. Give that direction an inactivity-based
	// drain window: active traffic refreshes the window, but a silent orphan can
	// no longer retain a goroutine, a netstack endpoint, and a copy buffer forever.
	lastActivity.Store(time.Now().UnixNano())
	timer := time.NewTimer(drainIdleTimeout)
	defer timer.Stop()

	for {
		select {
		case second := <-results:
			if second.err != nil && !errors.Is(second.err, net.ErrClosed) {
				return second.err
			}
			return nil
		case <-timer.C:
			remaining := drainIdleTimeout - time.Since(time.Unix(0, lastActivity.Load()))
			if remaining > 0 {
				timer.Reset(remaining)
				continue
			}
			_ = client.Close()
			_ = target.Close()
			<-results
			return nil
		}
	}
}
