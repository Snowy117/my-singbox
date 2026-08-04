@{
    # sing-box settings belong in config.yaml.  This file only contains
    # deployment settings used by the service-management scripts.
    DnsInboundTags = @('dns-in-v4', 'dns-in-v6')
    DnsFirewallRemoteAddress = 'LocalSubnet'
    DnsFirewallInterfaceAlias = 'vEthernet (Network Bridge)'
    PostStartTunWaitSeconds = 60

    SubStoreListen = '127.0.0.1'
    SubStoreBackendPort = 40008
    SubStoreFrontendPort = 40007
}

