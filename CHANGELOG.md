# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).



## [Unreleased]

### Changed

- Support multiple volumes to share between the host and the guest QEMU VM.

## [0.5.0] - 2021-05-18

### Added

- Added the possibility to share volumes between the host and the guest VM.

## [0.4.1] - 2021-02-16

### Fixed

- Change to new Flatcar GPG signing key and follow redirects.

## [0.4.0] - 2021-02-04

### Changed

- Build QEMU from source
- Upgrade QEMU to 5.2.0

## [0.3.0] - 2020-12-08

### Changed

- Switch from Fedora 32 to Fedora 33 (qemu 4.2.0 -> 5.0.0).

## [0.2.0] - 2020-07-01

### Changed

- Switch from Fedora 29 to Fedora 32 (qemu 3.0.0 -> 4.2.0).

## [0.1.0] - 2020-06-30

### Added

- Add github workflows.

### Changed

- Use `architect-orb` `v0.9.0`.

[Unreleased]: https://github.com/giantswarm/k8s-kvm/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/giantswarm/k8s-kvm/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/giantswarm/k8s-kvm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/giantswarm/k8s-kvm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/giantswarm/k8s-kvm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/giantswarm/k8s-kvm/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/giantswarm/k8s-kvm/releases/tag/v0.1.0
