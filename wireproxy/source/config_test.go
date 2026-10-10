package wireproxy

import (
	"github.com/go-ini/ini"
	"testing"
)

func loadIniConfig(config string) (*ini.File, error) {
	iniOpt := ini.LoadOptions{
		Insensitive:            true,
		AllowShadows:           true,
		AllowNonUniqueSections: true,
	}

	return ini.LoadSources(iniOpt, []byte(config))
}

func TestWireguardConfWithoutSubnet(t *testing.T) {
	const config = `
[Interface]
PrivateKey = LAr1aNSNF9d0MjwUgAVC4020T0N/E5NUtqVv5EnsSz0=
Address = 10.5.0.2
DNS = 1.1.1.1

[Peer]
PublicKey = e8LKAc+f9xEzq9Ar7+MfKRrs+gZ/4yzvpRJLRJ/VJ1w=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 94.140.11.15:51820
PersistentKeepalive = 25`
	var cfg DeviceConfig
	iniData, err := loadIniConfig(config)
	if err != nil {
		t.Fatal(err)
	}

	err = ParseInterface(iniData, &cfg)
	if err != nil {
		t.Fatal(err)
	}
}

func TestWireguardConfWithSubnet(t *testing.T) {
	const config = `
[Interface]
PrivateKey = LAr1aNSNF9d0MjwUgAVC4020T0N/E5NUtqVv5EnsSz0=
Address = 10.5.0.2/23
DNS = 1.1.1.1

[Peer]
PublicKey = e8LKAc+f9xEzq9Ar7+MfKRrs+gZ/4yzvpRJLRJ/VJ1w=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 94.140.11.15:51820
PersistentKeepalive = 25`
	var cfg DeviceConfig
	iniData, err := loadIniConfig(config)
	if err != nil {
		t.Fatal(err)
	}

	err = ParseInterface(iniData, &cfg)
	if err != nil {
		t.Fatal(err)
	}
}

func TestWireguardConfWithManyAddress(t *testing.T) {
	const config = `
[Interface]
PrivateKey = mBsVDahr1XIu9PPd17UmsDdB6E53nvmS47NbNqQCiFM=
Address = 100.96.0.190,2606:B300:FFFF:fe8a:2ac6:c7e8:b021:6f5f/128
DNS = 198.18.0.1,198.18.0.2

[Peer]
PublicKey = SHnh4C2aDXhp1gjIqceGhJrhOLSeNYcqWLKcYnzj00U=
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = 192.200.144.22:51820`
	var cfg DeviceConfig
	iniData, err := loadIniConfig(config)
	if err != nil {
		t.Fatal(err)
	}

	err = ParseInterface(iniData, &cfg)
	if err != nil {
		t.Fatal(err)
	}
}

// Legacy WARP installers emit one Address line per IP family.
func TestRepeatedAddressKeepsBothFamilies(t *testing.T) {
	iniData, err := loadIniConfig(`[Interface]
Address = 172.16.0.2/32
Address = 2001:db8::2/128
`)
	if err != nil {
		t.Fatal(err)
	}
	addresses, err := parseCIDRNetIP(iniData.Section("Interface"), "Address")
	if err != nil {
		t.Fatal(err)
	}
	if len(addresses) != 2 || !addresses[0].Is4() || !addresses[1].Is6() {
		t.Fatalf("repeated Address lost an IP family: %v", addresses)
	}
}

func TestRepeatedAddressResolvesEachEnvironmentValue(t *testing.T) {
	t.Setenv("WIREPROXY_TEST_V4", "172.16.0.2/32")
	t.Setenv("WIREPROXY_TEST_V6", "2001:db8::2/128")
	iniData, err := loadIniConfig("[Interface]\nAddress = $WIREPROXY_TEST_V4\nAddress = $WIREPROXY_TEST_V6\n")
	if err != nil {
		t.Fatal(err)
	}
	addresses, err := parseCIDRNetIP(iniData.Section("Interface"), "Address")
	if err != nil {
		t.Fatal(err)
	}
	if len(addresses) != 2 || !addresses[0].Is4() || !addresses[1].Is6() {
		t.Fatalf("repeated environment Address lost an IP family: %v", addresses)
	}
}
