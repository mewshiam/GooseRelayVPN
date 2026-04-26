// Package carrier implements the client side of the Apps Script transport:
// a long-poll loop that batches outgoing frames, POSTs them through a
// domain-fronted HTTPS connection, and routes the response frames back to
// their sessions.
package carrier

import (
	"context"
	"crypto/tls"
	"net"
	"net/http"
	"time"
)

// FrontingConfig describes how to reach script.google.com without revealing
// the real Host to a passive on-path observer: dial GoogleIP, do a TLS
// handshake with SNI=SNIHost. Go's default behavior of Host = URL.Host then
// routes the request to the right Google backend (and follows the Apps Script
// 302 redirect to script.googleusercontent.com correctly).
type FrontingConfig struct {
	GoogleIP string // "ip:443"
	SNIHost  string // e.g. "www.google.com"
}

// NewFrontedClient returns an *http.Client that dials cfg.GoogleIP regardless
// of the URL host and presents SNI=cfg.SNIHost in the TLS handshake.
//
// pollTimeout is the per-request ceiling; it should comfortably exceed the
// server's long-poll window (we use ~25s, default here is 60s).
func NewFrontedClient(cfg FrontingConfig, pollTimeout time.Duration) *http.Client {
	dialer := &net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			if cfg.GoogleIP != "" {
				return dialer.DialContext(ctx, "tcp", cfg.GoogleIP)
			}
			return dialer.DialContext(ctx, network, addr)
		},
		TLSClientConfig: &tls.Config{
			ServerName: cfg.SNIHost,
		},
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   15 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}

	return &http.Client{Transport: transport, Timeout: pollTimeout}
}
