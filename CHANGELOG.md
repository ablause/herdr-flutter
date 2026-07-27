# Changelog

## [0.3.0](https://github.com/ablause/herdr-flutter/compare/v0.2.0...v0.3.0) (2026-07-27)


### ⚠ BREAKING CHANGES

* the errors view is gone and the views renumber to 1 logs, 2 inspect, 3 net, 4 info. Errors now age out of the ring buffer with everything else at log_limit lines, where the list could not be evicted. Two places to look at one run costs more than losing the oldest error of a five thousand line session; typing exc and a space brings back the view of them alone.

### Features

* fold the errors view into the log ([#5](https://github.com/ablause/herdr-flutter/issues/5)) ([2399033](https://github.com/ablause/herdr-flutter/commit/239903376d426d43a6367798d26a725275efe4aa))


### Refactoring

* name the two clamp idioms in the controller ([2266787](https://github.com/ablause/herdr-flutter/commit/2266787ebe78acf0ece7226d6b1f5c1c5b03fbe3))

## [0.2.0](https://github.com/ablause/herdr-flutter/compare/v0.1.1...v0.2.0) (2026-07-27)


### Features

* **net:** add the HTTP traffic view ([#2](https://github.com/ablause/herdr-flutter/issues/2)) ([031af9a](https://github.com/ablause/herdr-flutter/commit/031af9a787a1ed606fd4bd8eeb5956d22adf171d))
* **ui:** colour the log from the record, and keep colours a line brings ([75af6a5](https://github.com/ablause/herdr-flutter/commit/75af6a505d015e5b8a9950fc1a7787d4925df47f))
* **ui:** make the tabs and lists clickable ([22086bd](https://github.com/ablause/herdr-flutter/commit/22086bd993366f994c84e7602c5f30c499550026))
* **ui:** put the chrome on one row and number the views ([002e645](https://github.com/ablause/herdr-flutter/commit/002e6458b466129c6e02680ef13506fe8e7303c9))
* **ui:** say what the app runs on, and where each widget was written ([afaa305](https://github.com/ablause/herdr-flutter/commit/afaa3056151d0aaddf8fe917e255907d3056b348))


### Fixes

* **ci:** keep release tags as v0.0.0, not component prefixed ([74f618e](https://github.com/ablause/herdr-flutter/commit/74f618e1d55139a6f504925b62215864cb94b16c))
* **cli:** treat a missing herdr binary as an unavailable call ([06a2a11](https://github.com/ablause/herdr-flutter/commit/06a2a11d1f680d2242547078f466c7a8b105a8ac))
* **discovery:** match the lowercase service line ([031af9a](https://github.com/ablause/herdr-flutter/commit/031af9a787a1ed606fd4bd8eeb5956d22adf171d))
* stop opening and resetting connections to find an app ([9265281](https://github.com/ablause/herdr-flutter/commit/9265281570f49edf0a598fea8c3b9a30eaa65cca))
* stop painting a frame after leaving the alternate screen ([84c30e2](https://github.com/ablause/herdr-flutter/commit/84c30e2a2cbe2f0e521a76b66bbdd8b45965d56c))


### Documentation

* record a demo of the sidebar beside the agent ([d4551a9](https://github.com/ablause/herdr-flutter/commit/d4551a9f553eefab53a27a04775cc3d9eb59aec3))
* record why the sidebar does not start the app ([65a81e5](https://github.com/ablause/herdr-flutter/commit/65a81e502f309fce8b59952073427a7bbdcde2a6))
* squeeze the demo recording to a third of its size ([f02faca](https://github.com/ablause/herdr-flutter/commit/f02facae43e2b5d0838516b354cce73db6ae073b))
