package acp

import (
	"context"
	"errors"

	sdk "github.com/coder/acp-go-sdk"
)

// The runtime's account (ACPSession's authenticate, logOut, providers, setProvider and
// disableProvider): asked of a session that went no further than the handshake.

// ErrNotSupported is a runtime whose handshake did not offer the call.
var ErrNotSupported = errors.New("the runtime does not offer this")

// CanLogOut and CanProviders are what the handshake offered.
func (s *Session) CanLogOut() bool    { return s.Init.AgentCapabilities.Auth.Logout != nil }
func (s *Session) CanProviders() bool { return s.Init.AgentCapabilities.Providers != nil }

// Authenticate is authenticate with one of the methods the handshake named.
func (s *Session) Authenticate(ctx context.Context, methodID string) error {
	_, err := s.conn.Authenticate(ctx, sdk.AuthenticateRequest{MethodId: methodID})
	return err
}

// LogOut is logout.
func (s *Session) LogOut(ctx context.Context) error {
	if !s.CanLogOut() {
		return ErrNotSupported
	}
	_, err := s.conn.Logout(ctx, sdk.LogoutRequest{})
	return err
}

// Providers is providers/list.
func (s *Session) Providers(ctx context.Context) ([]sdk.UnstableProviderInfo, error) {
	if !s.CanProviders() {
		return nil, ErrNotSupported
	}
	r, err := s.conn.UnstableListProviders(ctx, sdk.UnstableListProvidersRequest{})
	if err != nil {
		return nil, err
	}
	return r.Providers, nil
}

// SetProvider is providers/set: the provider routes the runtime's requests through the
// routing it has (ACP's providers/set needs its protocol and address).
func (s *Session) SetProvider(ctx context.Context, p sdk.UnstableProviderInfo) error {
	if !s.CanProviders() {
		return ErrNotSupported
	}
	if p.Current == nil {
		return ErrNotSupported
	}
	_, err := s.conn.UnstableSetProvider(ctx, sdk.UnstableSetProviderRequest{Id: p.Id, ApiType: p.Current.ApiType, BaseUrl: p.Current.BaseUrl})
	return err
}

// DisableProvider is providers/disable.
func (s *Session) DisableProvider(ctx context.Context, id string) error {
	if !s.CanProviders() {
		return ErrNotSupported
	}
	_, err := s.conn.UnstableDisableProvider(ctx, sdk.UnstableDisableProviderRequest{Id: id})
	return err
}
