﻿function New-VirtualNetworkResource
{
    Param
    (
        $Name,
        $Location,
        [string[]]
        $AddressSpacePrefixes,
        $Subnets
    )

    $addressSpace = @{'addressPrefixes' = $AddressSpacePrefixes;}

    $createProperties = @{"addressSpace" = $addressSpace; 'subnets'= $subnets;}

    $resource = New-ResourceTemplate -Type "Microsoft.Network/virtualNetworks" -Name $Name `
        -Location $Location -ApiVersion $Global:apiVersion -Properties $createProperties

    return $resource
}


function New-VirtualNetworkSubnet
{
    Param
    (
        $Name,
        $AddressPrefix,
        $NetworkSecurityGroup
    )

    $properties = @{'addressPrefix' = $addressPrefix}
    if ($networkSecurityGroup)
    {
        $properties.Add('networkSecurityGroup', @{'id' = $networkSecurityGroup})
    }

    $subnet = @{'name' = $Name; 'properties' = $properties}
    
    return $subnet
}

function New-NetworkInterfaceResource
{
    Param
    (
        $Name,
        $Location,
        [string]
        $SubnetReference,
        [string]
        $PublicIpAddressName,
        [string[]]
        $Dependecies
    )
    
    $publicIPAddress = @{'id' = '[resourceId(''Microsoft.Network/publicIPAddresses'',''{0}'')]' -f $PublicIpAddressName;}
    $subnet = @{'id' = $SubnetReference;}

    $ipConfigurations = @{ `
        'privateIPAllocationMethod' = "Dynamic"; `
        'publicIPAddress' = $publicIPAddress; `
        'subnet' = $subnet;}

    $ipConfigName = "{0}_config1" -f $Name

    $createProperties = @{'ipConfigurations' =  @(@{'name' =  $ipConfigName; 'properties' = $ipConfigurations;})}

    $resource = New-ResourceTemplate -Type "Microsoft.Network/networkInterfaces" -Name $Name `
        -Location $Location -ApiVersion $Global:apiVersion -Properties $createProperties -DependsOn $Dependecies

    return $resource
}

function New-PublicIpAddressResource
{
    Param
    (
        $Name,
        $Location,
        [string]
        $AllocationMethod,
        [string]
        $DnsName
    )
    
    $dnsSettings = @{'domainNameLabel' = $DnsName}
    
    $createProperties = @{'publicIPAllocationMethod' = $AllocationMethod; 'dnsSettings' = $dnsSettings}

    $resource = New-ResourceTemplate -Type "Microsoft.Network/publicIPAddresses" -Name $Name `
        -Location $Location -ApiVersion $Global:apiVersion -Properties $createProperties

    return $resource
}

function Get-AvailableAddressSpace
{
    [OutputType([string])]
    Param
    (
        [string[]]
        $addressSpaces
    )

    if ($addressSpaces -eq $null -or $addressSpaces.Length -eq 0)
    {
        # Return default, 0.0.0.1/20 network
        return "10.0.0.0/20"
    }

    $hostRanges = @()
    $addressSpaces | ForEach-Object {Get-HostRange $_} | Sort-Object -Property 'NetworkInt' | ForEach-Object {$hostRanges += $_}

    $minRange = [uint32]::MinValue
    $firstRangeNetwork = $hostRanges[0].Network.Split('.')
    if ($firstRangeNetwork[0] -eq 10)
    {
        $minRange = [uint32]([uint32]10 -shl 24) 
    } elseif ($firstRangeNetwork[0] -eq 172 -and $firstRangeNetwork[1] -eq 16)
    {
        $minRange = [uint32]([uint32]172 -shl 24) + [uint32]([uint32]16 -shl 16) 
    } elseif ($firstRangeNetwork[0] -eq 192 -and $firstRangeNetwork[1] -eq 168)
    {
        $minRange = [uint32]([uint32]192 -shl 24) + [uint32]([uint32]168 -shl 16) 
    } else
    {
        throw "Invalid IP range. Must conform rfc1918"
    }
     
    $networkRanges = @()
    $networkRanges += Get-FirstAvailableRange -Start $minRange -End ($hostRanges[0].NetworkInt - 1)

    for ($i = 0; $i -lt $hostRanges.Length - 1; $i++)
    { 
        $networkRanges += Get-FirstAvailableRange -Start ($hostRanges[$i].BroadcastInt + 1)  -End ($hostRanges[$i + 1].NetworkInt - 1)
    }

    $maxRange = [uint32]::MinValue
    $lastRangeNetwork = $hostRanges[$hostRanges.Length - 1].Network.Split('.')
    if ($lastRangeNetwork[0] -eq 10)
    {
        $maxRange = [uint32](([uint32]10 -shl 24) + ([uint32]255 -shl 16) + ([uint32]255 -shl 8) + [uint32]255) + 1        
    } elseif ($lastRangeNetwork[0] -eq 172 -and $lastRangeNetwork[1] -eq 16)
    {
        $maxRange = [uint32](([uint32]172 -shl 24) + ([uint32]31 -shl 16) + ([uint32]255 -shl 8) + [uint32]255) + 1
    } elseif ($lastRangeNetwork[0] -eq 192 -and $lastRangeNetwork[1] -eq 168)
    {
        $maxRange = [uint32](([uint32]192 -shl 24) + ([uint32]168 -shl 16) + ([uint32]255 -shl 8) + [uint32]255) + 1
    } else
    {
        throw "Invalid IP range. Must conform rfc1918"
    }

    $networkRanges += Get-FirstAvailableRange -Start ($hostRanges[$hostRanges.Length - 1].BroadcastInt + 1) -End $maxRange

    if (-not $networkRanges -or $networkRanges.Length -le 0)
    {
        return ""
    }

    $firstRange = $networkRanges[0]
    return "{0}/{1}" -f $firstRange.Network, $(Get-PrefixForNetwork $firstRange.Hosts)

}

function Get-HostRange
{
    [OutputType([PSCustomObject])]
    Param
    (
        [string]
        $cidrBlock
    )

    $network, [int]$cidrPrefix = $cidrBlock.Split('/')
    if ($cidrPrefix -eq 0)
    {
        throw "No network prefix is found"
    }

    $dottedDecimals = $network.Split('.')
    [uint32] $uintNetwork = [uint32]([uint32]$dottedDecimals[0] -shl 24) + [uint32]([uint32]$dottedDecimals[1] -shl 16) + [uint32]([uint32]$dottedDecimals[2] -shl 8) + [uint32]$dottedDecimals[3] 
    
    $networkMask = (-bnot [uint32]0) -shl (32 - $cidrPrefix)
    $broadcast = $uintNetwork -bor ((-bnot $networkMask) -band [uint32]::MaxValue) 

    $networkRange = @{'Network' = Get-DecimalIp $uintNetwork; 'Broadcast' = Get-DecimalIp $broadcast; `
        'Hosts' = ($broadcast - $uintNetwork - 1); 'StartHost' = Get-DecimalIp ($uintNetwork + 1); 'EndHost' = Get-DecimalIp($broadcast - 1); `
        'BroadcastInt' = $broadcast; 'NetworkInt' = $uintNetwork}
    return [PSCustomObject] $networkRange
}

function Get-DecimalIp
{
    [OutputType([string])]
    Param
    (
        [uint32]
        $uintIp
    )

    return "{0}.{1}.{2}.{3}" -f [int]($uintIp -shr 24), [int](($uintIp -shr 16) -band 255), [int](($uintIp -shr 8) -band 255), [int]($uintIp -band 255)
}

function Get-FirstAvailableRange
{
    [OutputType([PSCustomObject])]
    Param
    (
        [uint32]
        $Start,
        [uint32] 
        $End
    ) 
    
    if ($Start -ge $End)
    {
        return @()
    }

    $blockSize = 4096
    $rangesCount = [math]::Floor(($End - $Start) / $blockSize)
    $ranges = @()
    if ($rangesCount -gt 0) 
    {
        #for ($i = 0; $i -lt $rangesCount; $i++)
        # Just grab the first range, but leave the above for reference. The potential number of ranges can 
        # be quite large, so go for this optimization for the small block sizes.
        for ($i = 0; $i -lt 1; $i++)
        { 
            $uintNetwork = ($start + ($i * $blockSize))
            $broadcast = ($start + ($i + 1) * $blockSize -1)
            $networkRange = @{'Network' = Get-DecimalIp $uintNetwork; 'Broadcast' = Get-DecimalIp $broadcast; `
            'Hosts' = ($broadcast - $uintNetwork - 1); 'StartHost' = Get-DecimalIp ($uintNetwork + 1); 'EndHost' = Get-DecimalIp($broadcast - 1); `
            'BroadcastInt' = $broadcast; 'NetworkInt' = $uintNetwork}
            $ranges += $networkRange
        }
    }

    $remainingRange = ($End - $Start) % $blockSize

    if ($remainingRange -gt 0) {
        $uintNetwork = $start
        $broadcast = $start + $remainingRange
        $networkRange = @{'Network' = Get-DecimalIp $uintNetwork; 'Broadcast' = Get-DecimalIp $broadcast; `
        'Hosts' = ($broadcast - $uintNetwork - 1); 'StartHost' = Get-DecimalIp ($uintNetwork + 1); 'EndHost' = Get-DecimalIp($broadcast - 1); `
        'BroadcastInt' = $broadcast; 'NetworkInt' = $uintNetwork}
        $ranges += $networkRange
    }

    if($ranges.Count -gt 0)
    {
        return $ranges[0]
    }
}

function Get-PrefixForNetwork
{
    [OutputType([int])]
    Param
    (
        [uint32]
        $NetworkSize
    )

    $NetworkSize++
    
    $netPrefix = 0
    do
    {
        $NetworkSize = $NetworkSize -shr 1
        $netPrefix++
    }
    until ($NetworkSize -eq 0)

    return (32 - $netPrefix)
}

function Get-FirstSubnet
{
    [OutputType([string])]
    Param(
        [string]
        $AddressSpace
    )

    $network, [int]$cidrPrefix = $AddressSpace.Split('/')
    if ($cidrPrefix -eq 0)
    {
        throw "No network prefix is found"
    }

    if ($cidrPrefix -gt 28)
    {
        return "{0}/{1}" -f $network, $cidrPrefix
    }

    return  "{0}/{1}" -f $network, ($cidrPrefix + 2)
}
