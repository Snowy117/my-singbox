@{
    MixedListen = '0.0.0.0'
    MixedPort = 30890
    SingBoxApiEnabled = $true
    SingBoxApiListen = '127.0.0.1'
    SingBoxApiPort = 40090
    TunInterface = 'Meta'
    TunMtu = 1480

    SubStoreListen = '127.0.0.1'
    SubStoreBackendPort = 40008
    SubStoreFrontendPort = 40007

    TemplateUrl = 'https://raw.githubusercontent.com/Lanlan13-14/Rules-singbox/main/1.12.X/config_sub.json'

    EducationDomains = @('pku.edu.cn', 'openjudge.cn', 'qmazon.local')
    EducationCidrs = @('10.0.0.0/8', '162.105.0.0/16', '115.27.0.0/16')

    # sing-box 1.13 cannot automatically fail over between DNS servers.
    # Change these tags to one of the matching server tags below when needed.
    DirectDnsServer = 'CN-DNS-Ali'
    RemoteDnsServer = 'Global-DNS-Recipes'
    DnsStrategy = 'prefer_ipv6'
    Ipv4PreferredDomains = @('edu.cn', 'sukaka.ai6.me', 'luogu.com.cn')
    DnsClientSubnet = '115.27.215.1/24'
    FakeIpV4Range = '198.18.0.0/15'
    FakeIpV6Range = 'fd18:1111:1111::/64'
}

