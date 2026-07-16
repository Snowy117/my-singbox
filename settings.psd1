@{
    MixedListenAddresses = @('0.0.0.0', '::')
    MixedPort = 30890
    ClashApiEnabled = $true
    ClashApiListen = '127.0.0.1'
    ClashApiPort = 40090
    NativeApiEnabled = $true
    NativeApiListen = '127.0.0.1'
    NativeApiPort = 40091

    DnsListenAddresses = @('0.0.0.0', '::')
    DnsListenPort = 53
    DnsReuseAddr = $true
    DnsFirewallRemoteAddress = 'LocalSubnet'
    DnsFirewallInterfaceAlias = 'vEthernet (Network Bridge)'

    NativeApiAllowedOrigins = @(
        'http://127.0.0.1:40090',
        'http://localhost:40090'
    )

    TunInterface = 'Meta'
    TunMtu = 1480
    TunAddresses = @('172.18.0.1/30', 'fdfe:dcba:9876::1/126')
    TunDnsAddresses = @('172.18.0.2', 'fdfe:dcba:9876::2')
    TunRouteAddresses = @('0.0.0.0/1', '128.0.0.0/1', '::/1', '8000::/1')
    TunRouteExcludeAddresses = @('127.0.0.0/8', '::1/128')

    SubStoreListen = '127.0.0.1'
    SubStoreBackendPort = 40008
    SubStoreFrontendPort = 40007

    TemplateUrl = 'https://raw.githubusercontent.com/Lanlan13-14/Rules-singbox/main/1.12.X/config_sub.json'

    EducationDomains = @('pku.edu.cn', 'openjudge.cn', 'qmazon.local')
    EducationCidrs = @('10.0.0.0/8', '162.105.0.0/16', '115.27.0.0/16')

    # sing-box cannot automatically fail over between DNS servers.
    # Change these tags to one of the matching server tags below when needed.
    DirectDnsServer = 'CN-DNS-Ali'
    RemoteDnsServer = 'Global-DNS-Recipes'
    ProxyServerDnsServer = 'System-DNS'
    DnsStrategy = 'prefer_ipv6'
    Ipv4PreferredDomains = @('edu.cn', 'sukaka.ai6.me', 'luogu.com.cn')
    DnsClientSubnet = '115.27.215.1/24'
    FakeIpV4Range = '198.18.0.0/15'
    FakeIpV6Range = 'fd18:1111:1111::/64'
}

