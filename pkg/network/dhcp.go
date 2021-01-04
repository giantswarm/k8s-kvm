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
	"time"

	dhcp "github.com/krolaw/dhcp4"
	"github.com/krolaw/dhcp4/conn"
	"github.com/miekg/dns"
	log "github.com/sirupsen/logrus"

	"github.com/mazzy89/containervmm/pkg/api"
	"github.com/mazzy89/containervmm/pkg/util"
)

var leaseDuration, _ = time.ParseDuration("4294967295s") // Infinite lease time

// DHCPInterface describes the NIC of container
type DHCPInterface struct {
	VMIPNet    *net.IPNet
	GatewayIP  *net.IP
	VMTAP      string
	Bridge     string
	Hostname   string
	MACFilter  string
	dnsServers []byte
}

func StartDHCPServers(guest api.Guest, dhcpIfaces []DHCPInterface) error {
	// Generate the MAC addresses for the VM's adapters
	macAddresses := make([]string, 0, len(dhcpIfaces))
	if err := util.NewMAC(&macAddresses); err != nil {
		return fmt.Errorf("failed to generate MAC addresses: %v", err)
	}

	// Fetch the DNS servers given to the container
	clientConfig, err := dns.ClientConfigFromFile("/etc/resolv.conf")
	if err != nil {
		return fmt.Errorf("failed to get DNS configuration: %v", err)
	}

	for i := range dhcpIfaces {
		dhcpIface := &dhcpIfaces[i]

		// Set the VM hostname to the VM ID
		dhcpIface.Hostname = guest.Name

		// Set the MAC address filter for the DHCP server
		dhcpIface.MACFilter = macAddresses[i]

		// Add the DNS servers from the container
		dhcpIface.SetDNSServers(clientConfig.Servers)

		go func() {
			log.Infof("Starting DHCP server for interface %q (%s)\n", dhcpIface.Bridge, dhcpIface.VMIPNet.IP)

			if err := dhcpIface.StartBlockingServer(); err != nil {
				log.Errorf("%q DHCP server error: %v\n", dhcpIface.Bridge, err)
			}
		}()
	}

	return nil
}

// ServeDHCP responds to a DHCP request
func (i *DHCPInterface) ServeDHCP(p dhcp.Packet, msgType dhcp.MessageType, options dhcp.Options) dhcp.Packet {
	var respMsg dhcp.MessageType

	switch msgType {
	case dhcp.Discover:
		respMsg = dhcp.Offer
	case dhcp.Request:
		respMsg = dhcp.ACK
	}

	if respMsg != 0 {
		requestingMAC := p.CHAddr().String()

		if requestingMAC == i.MACFilter {
			opts := dhcp.Options{
				dhcp.OptionSubnetMask:       []byte(i.VMIPNet.Mask),
				dhcp.OptionRouter:           []byte(*i.GatewayIP),
				dhcp.OptionDomainNameServer: i.dnsServers,
				dhcp.OptionHostName:         []byte(i.Hostname),
			}

			optSlice := opts.SelectOrderOrAll(options[dhcp.OptionParameterRequestList])

			return dhcp.ReplyPacket(p, respMsg, *i.GatewayIP, i.VMIPNet.IP, leaseDuration, optSlice)
		}
	}

	return nil
}

// StartBlockingServer starts a blocking DHCP server on port 67
func (i *DHCPInterface) StartBlockingServer() error {
	packetConn, err := conn.NewUDP4BoundListener(i.Bridge, ":67")
	if err != nil {
		return err
	}

	return dhcp.Serve(packetConn, i)
}

// Parse the DNS servers for the DHCP server
func (i *DHCPInterface) SetDNSServers(dns []string) {
	for _, server := range dns {
		i.dnsServers = append(i.dnsServers, []byte(net.ParseIP(server).To4())...)
	}
}
