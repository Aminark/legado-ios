# ZIPFoundation 0.9.20

Source: https://github.com/weichsel/ZIPFoundation/tree/22787ffb59de99e5dc1fbfe80b19c97a904ad48d

The Sources directory and MIT license are unchanged. The package manifest omits upstream test targets.

The iOS app uses this local package for its synchronous local-book import and text-reading service. Readium uses a separate asynchronous fork with a different module (`ReadiumZIPFoundation`), but both remote repositories have the same SwiftPM identity. This local package keeps those dependencies distinct without changing existing import semantics. The macOS core test package continues to pin upstream 0.9.20.
