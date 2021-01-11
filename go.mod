module github.com/giantswarm/k8s-kvm

go 1.15

replace github.com/vishvananda/netlink => github.com/twelho/netlink v1.1.1-ageing

require (
	code.cloudfoundry.org/bytefmt v0.0.0-20200131002437-cf55d5288a48
	github.com/google/go-cmp v0.5.4 // indirect
	github.com/kata-containers/govmm v0.0.0-20201016132830-11b6ac380d2d
	github.com/krolaw/dhcp4 v0.0.0-20190909130307-a50d88189771
	github.com/miekg/dns v1.1.33
	github.com/onsi/ginkgo v1.14.2 // indirect
	github.com/onsi/gomega v1.10.3 // indirect
	github.com/schollz/progressbar/v3 v3.6.0
	github.com/sirupsen/logrus v1.7.0
	github.com/spf13/pflag v1.0.5
	github.com/vishvananda/netlink v1.1.0
	golang.org/x/crypto v0.0.0-20201012173705-84dcc777aaee
)
