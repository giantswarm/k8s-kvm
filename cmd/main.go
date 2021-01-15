/*

Copyright 2020 Salvatore Mazzarino

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

		https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package main

import (
	"compress/gzip"
	"encoding/base64"
	"flag"
	"fmt"
	"html/template"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	log "github.com/sirupsen/logrus"
	"github.com/spf13/pflag"

	"github.com/giantswarm/k8s-kvm/pkg/api"
	"github.com/giantswarm/k8s-kvm/pkg/disk"
	"github.com/giantswarm/k8s-kvm/pkg/distro"
	"github.com/giantswarm/k8s-kvm/pkg/hypervisor"
	"github.com/giantswarm/k8s-kvm/pkg/logs"
	"github.com/giantswarm/k8s-kvm/pkg/network"
)

// set log level
// TODO(mazzy89): allow to set log level
var logLevel = log.InfoLevel

type options struct {
	guestName string

	guestMemory       string
	guestCPUs         string
	guestRootDiskSize string

	flatcarChannel string
	flatcarVersion string

	// path where the Ignition config is stored
	flatcarIgnitionConfig string

	sanityChecks bool
}

func envValueOrDefaultString(envName string, def string) string {
	envVal := os.Getenv(envName)
	if envVal == "" {
		envVal = def
	}

	return envVal
}

func envValueOrDefaultBool(envName string, def bool) bool {
	envVal, err := strconv.ParseBool(os.Getenv(envName))
	if !envVal && err != nil {
		envVal = def
	}

	return envVal
}

func main() {
	var options options

	logs.Logger.SetLevel(logLevel)

	flag.StringVar(&options.guestName, "guest-name", envValueOrDefaultString("GUEST_NAME", "flatcar_production_qemu"), "guest name")

	flag.StringVar(&options.guestMemory, "guest-memory", envValueOrDefaultString("GUEST_MEMORY", "1024M"), "guest memory")
	flag.StringVar(&options.guestCPUs, "guest-cpus", envValueOrDefaultString("GUEST_CPUS", "1"), "guest cpus")

	flag.StringVar(&options.guestRootDiskSize, "guest-root-disk-size", envValueOrDefaultString("GUEST_ROOT_DISK_SIZE", "20G"), "guest root disk size")

	flag.StringVar(&options.flatcarChannel, "flatcar-channel", envValueOrDefaultString("FLATCAR_CHANNEL", "stable"), "flatcar channel")
	flag.StringVar(&options.flatcarVersion, "flatcar-version", envValueOrDefaultString("FLATCAR_VERSION", ""), "flatcar version")
	flag.StringVar(&options.flatcarIgnitionConfig, "flatcar-ignition", envValueOrDefaultString("FLATCAR_IGNITION", ""), "path of the Ignition config")

	flag.BoolVar(&options.sanityChecks, "sanity-checks", envValueOrDefaultBool("SANITY_CHECKS", true), "run sanity checks (GPG verification of images)")

	pflag.CommandLine.AddGoFlagSet(flag.CommandLine)
	flag.Parse()

	if options.flatcarVersion == "" {
		log.Fatal("Please specify a Flatcar version.")
	}

	// create Guest
	guest := api.Guest{Name: options.guestName, CPUs: options.guestCPUs, Memory: options.guestMemory}

	if options.flatcarIgnitionConfig != "" {
		ignitionBase64Reader, err := os.Open(options.flatcarIgnitionConfig)
		if err != nil {
			log.Fatalf("failed to open base64-encoded ignition: %v", err)
		}
		ignitionCompressedReader := base64.NewDecoder(base64.StdEncoding, ignitionBase64Reader)
		ignitionUncompressedReader, err := gzip.NewReader(ignitionCompressedReader)
		if err != nil {
			log.Fatalf("failed to unzip ignition: %v", err)
		}
		outputFile := fmt.Sprintf("%s.dec", options.flatcarIgnitionConfig)
		ignitionWriter, err := os.OpenFile(outputFile, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
		if err != nil {
			log.Fatalf("failed to open ignition output file %s for writing: %v", outputFile, err)
		}
		_, err = io.Copy(ignitionWriter, ignitionUncompressedReader)
		if err != nil {
			log.Fatalf("failed to write ignition output file: %v", err)
		}
		guest.OS.IgnitionConfig = outputFile
	}

	kernel, initrd, err := distro.DownloadImages(options.flatcarChannel, options.flatcarVersion, options.sanityChecks)
	if err != nil {
		log.Fatalf("An error occurred during the download of Flatcar %s %s images: %v", options.flatcarChannel, options.flatcarVersion, err)
	}

	// set kernel and initrd downloaded
	guest.OS.Kernel = kernel
	guest.OS.Initrd = initrd

	// Setup networking inside of the container, return the available interfaces
	dhcpIfaces, err := network.SetupInterfaces()
	if err != nil {
		log.Fatalf("An error occured during the the setup of the network: %v", err)
	}

	commands := []string{
		"qdisc del dev {{ .Interface }} handle ffff: ingress",
		"qdisc add dev {{ .Interface }} handle ffff: ingress",
		"filter add dev {{ .Interface }} parent ffff: protocol all u32 match u32 0 0 action pedit ex munge eth dst set {{ .Address }}",
	}
	for _, command := range commands {
		temp, err := template.New("args").Parse(command)
		if err != nil {
			log.Fatalf("create template failed for %s: %v", command, err)
		}
		var builder strings.Builder
		err = temp.Execute(&builder, struct {
			Interface string
			Address   string
		}{
			Interface: "eth0",
			Address:   dhcpIfaces[0].MACFilter,
		})
		if err != nil {
			log.Fatalf("template command failed: %v", err)
		}
		cmd := exec.Command("tc", command)
		err = cmd.Run()
		if err != nil {
			log.Fatalf("execute tc with args %s failed: %v", builder.String(), err)
		}
	}

	// Serve DHCP requests for those interfaces
	// This function returns the available IP addresses that are being
	// served over DHCP now
	if err = network.StartDHCPServers(guest, dhcpIfaces); err != nil {
		log.Fatalf("An error occured during the start of the DHCP servers: %v", err)
	}

	// bind DHCP Network Interfaces to the Guest object
	network.BindDHCPInterfaces(&guest, dhcpIfaces)

	// create rootfs
	sizes := []string{options.guestRootDiskSize}

	if err := disk.CreateDisks(&guest, sizes); err != nil {
		log.Fatalf("An error occured during the creation of disks: %v", err)
	}

	// execute QEMU
	if err = hypervisor.ExecuteQEMU(guest); err != nil {
		log.Fatalf("An error occured during the execution of QEMU: %v", err)
	}
}
