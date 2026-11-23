# Run on the Windows personal PC. This prints the current active LAN URL.
# It does not publish the service or configure HTTPS.
$configs = Get-NetIPConfiguration | Where-Object {
    $_.IPv4DefaultGateway -ne $null -and $_.IPv4Address -ne $null
}
if (-not $configs) {
    Write-Error 'No active IPv4 adapter with a default gateway was found.'
    exit 1
}
$configs | ForEach-Object {
    $alias = $_.InterfaceAlias
    foreach ($address in $_.IPv4Address) {
        Write-Output "$alias : http://$($address.IPAddress):8080/guacamole/"
    }
}
Write-Output 'LAN URL works only if port 8080 is published to a LAN-reachable interface and both devices can reach each other.'
