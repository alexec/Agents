package skillcatalog

import (
	"fmt"

	"github.com/alexec/agents/Go/wire"
)

// Error is a catalogue call that could not do what it was asked (DaemonAPI.CatalogError):
// which, as the sheet shows it, in Why.
type Error struct{ Why wire.CatalogError }

func (e *Error) Error() string { return Sentence(e.Why) }

func Unreachable(host string) *Error {
	return &Error{wire.CatalogError{Unreachable: &wire.CatalogErrorUnreachable{Host: host}}}
}
func RateLimited(retryAfter *int64) *Error {
	return &Error{wire.CatalogError{RateLimited: &wire.CatalogErrorRateLimited{RetryAfter: retryAfter}}}
}
func Unmanaged(path string) *Error {
	return &Error{wire.CatalogError{Unmanaged: &wire.CatalogErrorUnmanaged{Path: path}}}
}
func LockUnreadable(path string) *Error {
	return &Error{wire.CatalogError{LockUnreadable: &wire.CatalogErrorLockUnreadable{Path: path}}}
}
func NoPersonalHome() *Error  { return &Error{wire.CatalogError{NoPersonalHome: &struct{}{}}} }
func PreviewExpired() *Error  { return &Error{wire.CatalogError{PreviewExpired: &struct{}{}}} }
func ReplaceMismatch() *Error { return &Error{wire.CatalogError{ReplaceMismatch: &struct{}{}}} }
func NotAFolder(path string) *Error {
	return &Error{wire.CatalogError{NotAFolder: &wire.CatalogErrorNotAFolder{Path: path}}}
}
func CannotAdd(problems []wire.PreviewProblem) *Error {
	return &Error{wire.CatalogError{CannotAdd: &wire.CatalogErrorCannotAdd{Value: problems}}}
}
func NotManaged(name string) *Error {
	return &Error{wire.CatalogError{NotManaged: &wire.CatalogErrorNotManaged{Name: name}}}
}
func Failed(why string) *Error {
	return &Error{wire.CatalogError{Failed: &wire.CatalogErrorFailed{Value: why}}}
}

// Sentence is a refusal in a sentence, for the log and for a client that shows only the
// message (CatalogWords).
func Sentence(e wire.CatalogError) string {
	switch {
	case e.Unreachable != nil:
		return "Can't reach " + e.Unreachable.Host + "."
	case e.RateLimited != nil:
		return "GitHub is limiting requests. Try again in a few minutes."
	case e.Unmanaged != nil:
		return "A skill you made is already at " + e.Unmanaged.Path + ", so it was left alone."
	case e.LockUnreadable != nil:
		return e.LockUnreadable.Path + " could not be read, so it was not written."
	case e.NoPersonalHome != nil:
		return "This copy of the app has no personal ~/.agents."
	case e.PreviewExpired != nil:
		return "That preview has expired. Open the skill again."
	case e.NotAFolder != nil:
		return e.NotAFolder.Path + " is not a folder on this Mac."
	case e.ReplaceMismatch != nil:
		return "The skill there has changed. Open it again."
	case e.CannotAdd != nil:
		return "This skill can't be added."
	case e.NotManaged != nil:
		return e.NotManaged.Name + " was not added by the app or the skills tool."
	case e.Failed != nil:
		return fmt.Sprintf("It could not be added: %s.", e.Failed.Value)
	}
	return "It could not be done."
}
