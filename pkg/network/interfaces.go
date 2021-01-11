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

package network

import (
	"fmt"
	"net"

	log "github.com/sirupsen/logrus"
	"github.com/vishvananda/netlink"
)

// Array of container interfaces to ignore (not forward to vm)
var ignoreInterfaces = map[string]struct{}{
	"lo": {},
}

func SetupInterfaces() ([]DHCPInterface, error) {
	var dhcpIfaces []DHCPInterface

	ifaces, err := net.Interfaces()
	if err != nil || ifaces == nil || len(ifaces) == 0 {
		return nil, fmt.Errorf("cannot get local network interfaces: %v", err)
	}

	interfacesCount := 0
	for _, iface := range ifaces {
		// Skip the interface if it's ignored
		if _, ok := ignoreInterfaces[iface.Name]; ok {
			continue
		}

		// Try to transfer the address from the container to the DHCP server
		ipNet, gw, _, err := takeAddress(&iface)
		if err != nil {
			// Log the problem, but don't quit the function here as there might be other good interfaces
			log.Errorf("parsing interface %q failed: %w", iface.Name, err)

			// Try with the next interface
			continue
		}

		dhcpIface, err := bridge(&iface)
		if err != nil {
			// Log the problem, but don't quit the function here as there might be other good interfaces
			// Don't set shouldRetry here as there is no point really with retrying with this interface
			// that seems broken/unsupported in some way.
			log.Errorf("bridging interface %q failed: %v", iface.Name, err)
			// Try with the next interface
			continue
		}

		dhcpIface.VMIPNet = ipNet
		dhcpIface.GatewayIP = gw

		dhcpIfaces = append(dhcpIfaces, *dhcpIface)

		// This is an interface we care about
		interfacesCount++
	}

	if interfacesCount == 0 {
		return nil, fmt.Errorf("no active or valid interfaces available yet")
	}

	return dhcpIfaces, nil
}

// takeAddress removes the first address of an interface and returns it and the appropriate gateway
func takeAddress(iface *net.Interface) (*net.IPNet, *net.IP, bool, error) {
	addrs, err := iface.Addrs()
	if err != nil || addrs == nil || len(addrs) == 0 {
		// set the bool to true so the caller knows to retry
		return nil, nil, true, fmt.Errorf("interface %q has no address", iface.Name)
	}

	for _, addr := range addrs {
		var ip net.IP
		var mask net.IPMask

		switch v := addr.(type) {
		case *net.IPNet:
			ip = v.IP
			mask = v.Mask
		case *net.IPAddr:
			ip = v.IP
			mask = ip.DefaultMask()
		}

		if ip == nil {
			continue
		}

		ip = ip.To4()
		if ip == nil {
			continue
		}

		link, err := netlink.LinkByName(iface.Name)
		if err != nil {
			return nil, nil, false, fmt.Errorf("failed to get interface %q by name: %v", iface.Name, err)
		}

		var gw *net.IP
		routes, err := netlink.RouteList(link, netlink.FAMILY_ALL)
		if err != nil {
			return nil, nil, false, fmt.Errorf("failed to get default gateway for interface %q: %v", iface.Name, err)
		}
		for _, rt := range routes {
			if rt.Gw != nil {
				gw = &rt.Gw
				break
			}
		}

		delAddr := &netlink.Addr{
			IPNet: &net.IPNet{
				IP:   ip,
				Mask: mask,
			},
		}
		if err = netlink.AddrDel(link, delAddr); err != nil {
			return nil, nil, false, fmt.Errorf("failed to remove address %q from interface %q: %v", delAddr, iface.Name, err)
		}

		log.Infof("Moving IP address %s (%s) with gateway %s from container to guest", ip.String(), maskString(mask), gw.String())

		return &net.IPNet{
			IP:   ip,
			Mask: mask,
		}, gw, false, nil
	}

	return nil, nil, false, fmt.Errorf("interface %s has no valid addresses", iface.Name)
}

// bridge creates the TAP device and performs the bridging, returning the base configuration for a DHCP server
func bridge(iface *net.Interface) (*DHCPInterface, error) {
	tapName := "tap-" + iface.Name
	bridgeName := "br-" + iface.Name

	eth, err := netlink.LinkByIndex(iface.Index)
	if err != nil {
		return nil, err
	}

	tuntap, err := createTAPAdapter(tapName)
	if err != nil {
		return nil, fmt.Errorf("creation tap interface %q failed: %w", tapName, err)
	}

	bridge, err := createBridge(bridgeName)
	if err != nil {
		return nil, fmt.Errorf("creation bridge %q failed: %w", bridgeName, err)
	}

	if err := setMaster(bridge, tuntap, eth); err != nil {
		return nil, fmt.Errorf("failed to set master: %v", err)
	}

	return &DHCPInterface{
		VMTAP:  tapName,
		Bridge: bridgeName,
	}, nil
}

// createTAPAdapter creates a new TAP device with the given name
func createTAPAdapter(tapName string) (*netlink.Tuntap, error) {
	la := netlink.NewLinkAttrs()
	la.Name = tapName
	tuntap := &netlink.Tuntap{
		LinkAttrs: la,
		Mode:      netlink.TUNTAP_MODE_TAP,
	}
	return tuntap, addLink(tuntap)
}

// createBridge creates a new bridge device with the given name
func createBridge(bridgeName string) (*netlink.Bridge, error) {
	la := netlink.NewLinkAttrs()
	la.Name = bridgeName

	// Disable MAC address age tracking. This causes issues in the container,
	// the bridge is unable to resolve MACs from outside resulting in it never
	// establishing the internal routes. This "optimization" is only really useful
	// with more than two interfaces attached to the bridge anyways, so we're not
	// taking any performance hit by disabling it here.
	ageingTime := uint32(0)
	bridge := &netlink.Bridge{LinkAttrs: la, AgeingTime: &ageingTime}
	return bridge, addLink(bridge)
}

// addLink creates the given link and brings it up
func addLink(link netlink.Link) (err error) {
	if err = netlink.LinkAdd(link); err == nil {
		err = netlink.LinkSetUp(link)
	}

	return
}

// This is a MAC address persistence workaround, netlink.LinkSetMaster{,ByIndex}()
// has a bug that arbitrarily changes the MAC addresses of the bridge and virtual
// device to be bound to it. TODO: Remove when fixed upstream
func setMaster(master netlink.Link, links ...netlink.Link) error {
	masterIndex := master.Attrs().Index
	masterMAC, err := getMAC(master)
	if err != nil {
		return err
	}

	for _, link := range links {
		mac, err := getMAC(link)
		if err != nil {
			return err
		}

		if err = netlink.LinkSetMasterByIndex(link, masterIndex); err != nil {
			return err
		}

		if err = netlink.LinkSetHardwareAddr(link, mac); err != nil {
			return err
		}
	}

	return netlink.LinkSetHardwareAddr(master, masterMAC)
}

// getMAC fetches the generated MAC address for the given link
func getMAC(link netlink.Link) (addr net.HardwareAddr, err error) {
	// The attributes of the netlink.Link passed to this function do not contain HardwareAddr
	// as it is expected to be generated by the networking subsystem. Thus, "reload" the Link
	// by querying it to retrieve the generated attributes after the link has been created.
	if link, err = netlink.LinkByIndex(link.Attrs().Index); err != nil {
		return
	}

	addr = link.Attrs().HardwareAddr
	return
}

func maskString(mask net.IPMask) string {
	if len(mask) < 4 {
		return "<nil>"
	}

	return fmt.Sprintf("%d.%d.%d.%d", mask[0], mask[1], mask[2], mask[3])
}
