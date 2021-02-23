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

package root

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"github.com/spf13/viper"

	"github.com/giantswarm/k8s-kvm/pkg/api"
	"github.com/giantswarm/k8s-kvm/pkg/disk"
	"github.com/giantswarm/k8s-kvm/pkg/distro"
	"github.com/giantswarm/k8s-kvm/pkg/hypervisor"
	"github.com/giantswarm/k8s-kvm/pkg/network"
	"github.com/giantswarm/k8s-kvm/pkg/util"
)

const (
	cfgGuestName            = "guest-name"
	cfgGuestMemory          = "guest-memory"
	cfgGuestCPUs            = "guest-cpus"
	cfgGuestRootDiskSize    = "guest-root-disk-size"
	cfgGuestAdditionalDisks = "guest-additional-disks"
	cfgGuestHostVolumes     = "guest-host-volumes"
	cfgGuestDNSServers      = "guest-dns-servers"
	cfgGuestNTPServers      = "guest-ntp-servers"

	cfgFlatcarChannel      = "flatcar-channel"
	cfgFlatcarVersion      = "flatcar-version"
	cfgFlatcarIgnition     = "flatcar-ignition"
	cfgFlatcarIgnitionPath = "flatcar-ignition-dir"

	cfgDebug        = "debug"
	cfgSanityChecks = "sanity-checks"

	targetName = "containervmm"
)

var c = viper.New()

func configBoolVar(flags *pflag.FlagSet, key string, defaultValue bool, description string) {
	flags.Bool(key, defaultValue, description)
	_ = c.BindPFlag(key, flags.Lookup(key))
}

func configStringVar(flags *pflag.FlagSet, key, defaultValue, description string) {
	flags.String(key, defaultValue, description)
	_ = c.BindPFlag(key, flags.Lookup(key))
}

func configStringSlice(flags *pflag.FlagSet, key string, defaultValue []string, description string) {
	flags.StringSlice(key, defaultValue, description)
	_ = c.BindPFlag(key, flags.Lookup(key))
}

// rootCmd represents the base command when called without any subcommands
var rootCmd = &cobra.Command{
	Use:     fmt.Sprintf("%s [options]", targetName),
	Short:   "Container Virtual Machine Manager",
	Long:    `Container Virtual Machine Manager spins up a Virtual Machine inside a container`,
	Example: fmt.Sprintf("%s --flatcar-version=2605.6.0", targetName),
	RunE: func(cmd *cobra.Command, args []string) error {
		// create Guest API object
		guest := api.Guest{
			Name:   c.GetString(cfgGuestName),
			CPUs:   c.GetString(cfgGuestCPUs),
			Memory: c.GetString(cfgGuestMemory),
		}

		kernel, initrd, err := distro.DownloadImages(c.GetString(cfgFlatcarChannel), c.GetString(cfgFlatcarVersion), c.GetBool(cfgSanityChecks))
		if err != nil {
			return fmt.Errorf("an error occurred during the download of Flatcar %s %s images: %v",
				c.GetString(cfgFlatcarChannel), c.GetString(cfgFlatcarVersion), err)
		}

		// set kernel and initrd downloaded
		guest.OS.Kernel = kernel
		guest.OS.Initrd = initrd

		// set Ignition Config
		// this expect the path where the plain-text Ignition file is stored
		b64Ignition := c.GetString(cfgFlatcarIgnition)
		dirIgnition := c.GetString(cfgFlatcarIgnitionPath)

		if b64Ignition != "" {
			absIgnitionPath, err := util.DecodeBase64ToFile(b64Ignition, dirIgnition)
			if err != nil {
				return fmt.Errorf("an error occured during the decoding of Ignition config")
			}

			guest.OS.IgnitionConfig = absIgnitionPath
		}

		// Setup networking inside of the container, return the available interfaces
		dhcpIfaces, err := network.SetupInterfaces(&guest)
		if err != nil {
			return fmt.Errorf("an error occured during the the setup of the network: %v", err)
		}

		// Serve DHCP requests for those interfaces
		// The function returns the available IP addresses that are being
		// served over DHCP now
		dnsServers := c.GetStringSlice(cfgGuestDNSServers)
		ntpServers := c.GetStringSlice(cfgGuestNTPServers)

		if err = network.StartDHCPServers(guest, dhcpIfaces, dnsServers, ntpServers); err != nil {
			return fmt.Errorf("an error occured during the start of the DHCP servers: %v", err)
		}

		// create rootfs and other additional volumes
		gDisks := guest.Disks
		gDisks = append(gDisks, api.Disk{
			ID:     "rootfs",
			Size:   c.GetString(cfgGuestRootDiskSize),
			IsRoot: true,
		})

		for _, gd := range c.GetStringSlice(cfgGuestAdditionalDisks) {
			id, size := parseStringSliceFlag(gd)

			gDisks = append(gDisks, api.Disk{
				ID:     id,
				Size:   size,
				IsRoot: false,
			})
		}

		if err := disk.CreateDisks(&guest); err != nil {
			return fmt.Errorf("an error occured during the creation of disks: %v", err)
		}

		for _, gv := range c.GetStringSlice(cfgGuestHostVolumes) {
			mountTag, hostPath := parseStringSliceFlag(gv)

			guest.HostVolumes = append(guest.HostVolumes, api.HostVolume{
				MountTag: mountTag,
				HostPath: hostPath,
			})
		}

		// execute QEMU
		if err = hypervisor.ExecuteQEMU(guest); err != nil {
			return fmt.Errorf("an error occured during the execution of QEMU: %v", err)
		}

		return nil
	},
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	cobra.OnInitialize(initConfig)

	flags := rootCmd.PersistentFlags()

	configStringVar(flags, cfgGuestName, "flatcar_production_qemu", "guest name")
	configStringVar(flags, cfgGuestMemory, "1024M", "guest memory")
	configStringVar(flags, cfgGuestCPUs, "1", "guest cpus")
	configStringVar(flags, cfgGuestRootDiskSize, "20G", "guest root disk size")

	configStringSlice(flags, cfgGuestAdditionalDisks, []string{}, "guest additional disk to mount (i.e. \"dockerfs:20GB\")")
	configStringSlice(flags, cfgGuestHostVolumes, []string{}, "guest host volume (i.e. \"datashare:/usr/data\")")
	configStringSlice(flags, cfgGuestDNSServers, []string{}, "guest DNS Servers. If left empty, the DNS servers given are the one of the container")
	configStringSlice(flags, cfgGuestNTPServers, []string{}, "guest NTP Servers. If left empty, the NTP servers set are the default one from the distro")

	configStringVar(flags, cfgFlatcarChannel, "stable", "flatcar channel (i.e. stable, beta, alpha)")
	configStringVar(flags, cfgFlatcarVersion, "", "flatcar version")
	configStringVar(flags, cfgFlatcarIgnition, "", "base64-encoded Ignition Config")
	configStringVar(flags, cfgFlatcarIgnitionPath, "/", "dir path of the Ignition config")

	configBoolVar(flags, cfgSanityChecks, true, "run sanity checks (GPG verification of images)")
	configBoolVar(flags, cfgDebug, false, "enable debug")
}

func initConfig() {
	c.SetEnvPrefix(targetName)
	replacer := strings.NewReplacer("-", "_")
	c.SetEnvKeyReplacer(replacer)

	c.AutomaticEnv() // read in environment variables that match
}

func parseStringSliceFlag(input string) (string, string) {
	s := strings.Split(input, ":")

	return s[0], s[1]
}
