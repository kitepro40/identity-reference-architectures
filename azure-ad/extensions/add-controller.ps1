﻿# $DomainName         -  The fully qualified domain name (FQDN) of the domain the Domain Controller will be joining.
# $SiteName           -  The name of the site this Domain Controller will be added to.
# $PrimaryDcIpAddress -  IP Address of the primary domain controller
# $AdminCreds         -  a PSCredentials object that contains username and password 
#                        that will be assigned to the Domain Administrator account
# $SafeModeAdminCreds -  a PSCredentials object that contains the password that will
#                        be assigned to the Safe Mode Administrator account
# $RetryCount         -  defines how many retries should be performed while waiting
#                        for the domain to be provisioned
# $RetryIntervalSec   -  defines the seconds between each retry to check if the 
#                        domain has been provisioned
Configuration AddController {
    param
    #v1.4
    (
        [Parameter(Mandatory)]
        [string]$DomainName,

        [Parameter(Mandatory=$True)]
        [string]$SiteName,
        
        [Parameter(Mandatory)]
        [string]$PrimaryDcIpAddress,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SafeModeAdminCreds,

        [Int]$RetryCount=30,
        [Int]$RetryIntervalSec=60
    )

    Import-DscResource -ModuleName xStorage, xActiveDirectory, xNetworking, xPendingReboot

    [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($AdminCreds.UserName)", $AdminCreds.Password)
    [System.Management.Automation.PSCredential ]$SafeDomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($SafeModeAdminCreds.UserName)", $SafeModeAdminCreds.Password)

    $Interface = Get-NetAdapter|Where-Object Name -Like "Ethernet*"|Select-Object -First 1
    $InterfaceAlias = $($Interface.Name)
    
    Node localhost
    {
        LocalConfigurationManager
        {            
            ActionAfterReboot = 'ContinueConfiguration'            
            ConfigurationMode = 'ApplyOnly'            
            RebootNodeIfNeeded = $true            
        } 

        xWaitforDisk Disk2
        {
            DiskId = 2
            RetryIntervalSec = 60
            RetryCount = 20
        }
        
        xDisk FVolume
        {
            DiskId = 2
            DriveLetter = 'F'
            FSLabel = 'Data'
            FSFormat = 'NTFS'
            DependsOn = '[xWaitForDisk]Disk2'
        }        

        WindowsFeature DNS 
        { 
            Ensure = "Present" 
            Name = "DNS"
            IncludeAllSubFeature = $true
        }

        # Allow this machine to find the PDC and its DNS server
        [ScriptBlock]$SetScript =
        {
            Set-DnsClientServerAddress -InterfaceAlias ("$InterfaceAlias") -ServerAddresses ("$PrimaryDcIpAddress")
        }
        
        Script SetDnsServerAddressToFindPDC
        {
            GetScript = {return @{}}
            TestScript = {return $false} # Always run the SetScript for this.
            SetScript = $SetScript.ToString().Replace('$PrimaryDcIpAddress', $PrimaryDcIpAddress).Replace('$InterfaceAlias', $InterfaceAlias)
        }

        WindowsFeature ADDSInstall 
        { 
            Ensure = "Present" 
            Name = "AD-Domain-Services"
            IncludeAllSubFeature = $true
        }

        WindowsFeature RSAT
        {
             Ensure = "Present"
             Name = "RSAT"
        }        

        xADDomainController SecondaryDC
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainCreds
            SafemodeAdministratorPassword = $SafeDomainCreds
            SiteName = $SiteName
            DatabasePath = "F:\Adds\NTDS"
            LogPath = "F:\Adds\NTDS"
            SysvolPath = "F:\Adds\SYSVOL"
            DependsOn = @("[Script]SetDnsServerAddressToFindPDC"), "[xWaitForDisk]Disk2","[WindowsFeature]ADDSInstall"
        }

        # Now make sure this computer uses itself as a DNS source
        xDnsServerAddress DnsServerAddress2
        {
            Address        = @('127.0.0.1', $PrimaryDcIpAddress)
            InterfaceAlias = $InterfaceAlias
            AddressFamily  = 'IPv4'
            DependsOn = "[xADDomainController]SecondaryDC"
        }

        xPendingReboot Reboot2
        { 
            Name = "RebootServer"
            DependsOn = "[xADDomainController]SecondaryDC"
        }

   }
}