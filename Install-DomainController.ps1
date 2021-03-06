﻿<#
.Synopsis
   Installs DFirst DC in a new domain in a new Forest
.DESCRIPTION
   The information in the XML file determines whether the current DC will join an existing forest/domain or create a new one.
   This is for building a new forest. Both the domain and forest will be created new, and should not exist.
.EXAMPLE
   Install-DomainController.ps1
.NOTES
   Author : Ben van Zanten
   Company: Valid
   Date   : Dec 2015
   Version: 1.0

   History:  1.0  Initial version
#>
[CmdletBinding(SupportsShouldProcess=$true, 
                  ConfirmImpact='Medium')]

    Param
    (
        # Name of the input file, default is: ADStructure.xml
        [Parameter(Mandatory=$false,Position=1, 
                   ValueFromPipeline=$false,
                   ValueFromPipelineByPropertyName=$false, 
                   ValueFromRemainingArguments=$false)]
                   [ValidateScript({Test-Path $_})]
        [string]$XmlFile='.\ADStructure.xml',

    # Name of the domain. For instance psdemo.com. If not given, the domain from the XML is used
    [Parameter(Mandatory=$False,Position=2)]
    [string]$DomainName
    )



    Begin {
        Import-Module .\DeployAdLib.psd1
        # Test for elevation :
        if (-not(Test-AdminStatus)) {
            Write-Error "Run this script elevated! This script requires administrative permissions."
            break
        }
        $domName = Get-DomainName -XmlFile $XmlFile -DomainName $DomainName
        [xml]$forXML = Get-Content $XmlFile
        $domXML = $forXML.forest.domains.domain | ? { $_.name -eq $domName }

        $domName
    }

    Process
    {

        #
        #  Here starts the real work...
        #
        
        # $Pwd = Read-Host -Prompt "Password:" –AsSecureString
        $Pwd = ConvertTo-SecureString "Password1" -AsPlaintext –Force

        $ComputerName = [System.Environment]::MachineName

        $SiteName = "Default-First-Site-Name"
        $Site = $forXML.forest.sites.site | Where-Object { $_.servers.server.name -match $Env:ComputerName }
        if ($Site) { $SiteName = $Site.name }

        #
        #  Default installation parameters, for ALL types of DC. (New forest, new Domain in existing forest, new DC in existing Domain)
        #
        $ArgsDcPromo = @{
            "DatabasePath"                  = $domXML.DCs.parameters.DatabasePath
            "LogPath"                       = $domXML.DCs.parameters.LogPath
            "SysvolPath"                    = $domXML.DCs.parameters.SysvolPath
            "InstallDns"                    = $True
            "NoRebootOnCompletion"          = $True
            "SafeModeAdministratorPassword" = $Pwd
        }

        # Install DC binaries if that hasn't been done before...
        if (!(Get-WindowsFeature -Name AD-Domain-Services ).Installed) {
            Install-WindowsFeature -Name AD-Domain-Services,DNS -IncludeManagementTools
        }

        # If Current computername = FSMO SchemaMaster, then create a new Forest + Domain
        # If Current computername = FSMO PDC, then create a new Domain in existing forest
        # Otherwise, assume Forest & Domain already present on another machine, Create additional DC in existing Domain.


        if ($ComputerName -eq $forXML.forest.parameters.FSMO.Schema) {
            #
            # Schema master!!! create a new forest.
            #
            # https://technet.microsoft.com/en-us/library/hh974720(v=wps.630).aspx
            # Parameter Set: ADDSForest
            # Install-ADDSForest -DomainName <String> [-CreateDnsDelegation] [-DatabasePath <String> ] [-DnsDelegationCredential <PSCredential> ] [-DomainMode <DomainMode> ] [-DomainNetbiosName <String> ] [-Force] [-ForestMode <ForestMode> ] [-InstallDns] [-LogPath <String> ] [-NoDnsOnNetwork] [-NoRebootOnCompletion] [-SafeModeAdministratorPassword <SecureString> ] [-SkipAutoConfigureDns] [-SkipPreChecks] [-SysvolPath <String> ] [-Confirm] [-WhatIf] [ <CommonParameters>]
            #
            # Add specific parameters in case of a new forest...

            $ArgsDcPromo.Add("DomainName"       , $domXML.dnsname            ) # "psdemo.com"
            $ArgsDcPromo.Add("DomainNetbiosName", $domXML.Name               ) # "PSDEMO"
            $ArgsDcPromo.Add("DomainMode"       , $domXML.parameters.DFL     ) # 6   "Win2012R2"
            $ArgsDcPromo.Add("ForestMode"       , $forXML.forest.parameters.FFL ) # 6   "Win2012R2"

            Write-Host "About to Promote DC in a new forest, with the following parameters:"
            $ArgsDcPromo

            Write-Host "Verifying Forest installation..."
            Test-ADDSForestInstallation @ArgsDcPromo
    
            Install-ADDSForest @ArgsDcPromo


        } elseif ($ComputerName -eq $domXML.parameters.FSMO.PDC) {
            #
            # PDC!!! Create a new domain in existing forest
            #
            # https://technet.microsoft.com/en-us/library/hh974722(v=wps.630).aspx
            # Parameter Set: ADDSDomain
            # Install-ADDSDomain -NewDomainName <String> -ParentDomainName <String> [-ADPrepCredential <PSCredential> ] [-AllowDomainReinstall] [-CreateDnsDelegation] [-Credential <PSCredential> ] [-DatabasePath <String> ] [-DnsDelegationCredential <PSCredential> ] [-DomainMode <DomainMode> ] [-DomainType <DomainType> ] [-Force] [-InstallDns] [-LogPath <String> ] [-NewDomainNetbiosName <String> ] [-NoDnsOnNetwork] [-NoGlobalCatalog] [-NoRebootOnCompletion] [-ReplicationSourceDC <String> ] [-SafeModeAdministratorPassword <SecureString> ] [-SiteName <String> ] [-SkipAutoConfigureDns] [-SkipPreChecks] [-SysvolPath <String> ] [-Confirm] [-WhatIf] [ <CommonParameters>]
            # -NewDomainName<String>     If the value set for -DomainType is set to "TreeDomain", this parameter can be used to specify the fully qualified domain name (FQDN) for the new domain tree (for example, "contoso.com"). If the value set for -DomainType is set to "ChildDomain", this parameter can be used to specify a single label domain name for the child domain (for example, specify "corp" to make a new doman "corp.contoso.com" if the new domain is in the contoso.com domain tree).
            # -ParentDomainName<String>  Specifies the fully qualified domain name (FQDN) of an existing parent domain. 
            # -DomainType<DomainType>    Indicates the type of domain that you want to create: a new domain tree in an existing forest (supported values are "TreeDomain" or "tree"), a child of an existing domain (supported values are "ChildDomain" or "child"). The default is ChildDomain.
            #
            # Add specific parameters in case of a new domain in existing forest...

            $ArgsDcPromo.Add("DomainMode"       , $domXML.parameters.DFL    ) # 6   "Win2012R2"
            $ArgsDcPromo.Add("SiteName"         , $SiteName )

            # Add specific parameters for the location of the domain in the forest.
            #  IF  lastpart (psdemo.com) of the newDomainName (test.psdemo.com)  is an existing domain.. Then this domain will be child of existing.
            #     So:  remove FIRST name from the dnsdomainname (test.psdemo.com -> test)  and check if the remaining domain is existing.

            [string[]]$arrDom=$domxml.dnsname.Split('.')
            if ($arrDom.Length -gt 2) {

                $ParentDom = $arrDom[1..($arrDom.Length-1)] -join '.'

                Write-Host "About to Promote DC in an existing forest, new domain, specify Credentials to  join the existing forest"
                $JoinCred = Get-Credential "$ParentDom\Administrator"
                $ArgsDcPromo.Add("Credential"       , $JoinCred                 )

                if ( $forXML.forest.domains.domain | Where-Object { $_.dnsname -eq $parentDom } ) {
                    $ArgsDcPromo.Add("DomainType", "ChildDomain"                 )
                    $ArgsDcPromo.Add("ParentDomainName", $ParentDom              ) # $parentDom = "psdemo.com"   dnsname = "test.psdemo.com"
                    $ArgsDcPromo.Add("NewDomainName", $domXML.name               ) # "psdemo"
                    $ArgsDcPromo.Add("NewDomainNetbiosName", $domXML.Name        ) # "PSDEMO"
                } else {
                    $ArgsDcPromo.Add("DomainType", "TreeDomain"                  )
                    $ArgsDcPromo.Add("ParentDomainName", $ParentDom              ) # $parentDom = "psdemo.com"   dnsname = "test.psdemo.com"
                    $ArgsDcPromo.Add("NewDomainName", $domXML.dnsname            ) # "psdemo.com"
                    $ArgsDcPromo.Add("NewDomainNetbiosName", $domXML.Name        ) # "PSDEMO"
                }
            }

            # Optional Parameters..
            $ReplicationSourceDC = ($domxml.DCs.DC | Where-Object {$_.Name -eq $ComputerName } ).ReplicationSourceDC
            if ($ReplicationSourceDC) {
                Write-Verbose "Adding ReplicationSourceDC : $ReplicationSourceDC from optional parameter"
                $ArgsDcPromo.Add("ReplicationSourceDC"  , $ReplicationSourceDC )
            }

            Write-Host "About to Promote DC in an existing forest, in a new domain, with the following parameters:"
            $ArgsDcPromo

            Test-ADDSDomainInstallation @ArgsDcPromo

            Install-ADDSDomain @ArgsDcPromo
 

        } elseif ($domXML.DCs.dc | Where-Object { $_.Name -eq $ComputerName }) {
            #
            # DC is present in the DCs, so Additional DC in existing Domain
            #
            # https://technet.microsoft.com/en-us/library/hh974723(v=wps.630).aspx
            # Parameter Set: ADDSDomainController
            # Install-ADDSDomainController -DomainName <String> [-ADPrepCredential <PSCredential> ] [-AllowDomainControllerReinstall] [-ApplicationPartitionsToReplicate <String[]> ] [-CreateDnsDelegation] [-Credential <PSCredential> ] [-CriticalReplicationOnly] [-DatabasePath <String> ] [-DnsDelegationCredential <PSCredential> ] [-Force] [-InstallationMediaPath <String> ] [-InstallDns] [-LogPath <String> ] [-MoveInfrastructureOperationMasterRoleIfNecessary] [-NoDnsOnNetwork] [-NoGlobalCatalog] [-NoRebootOnCompletion] [-ReplicationSourceDC <String> ] [-SafeModeAdministratorPassword <SecureString> ] [-SiteName <String> ] [-SkipAutoConfigureDns] [-SkipPreChecks] [-SystemKey <SecureString> ] [-SysvolPath <String> ] [-Confirm] [-WhatIf] [ <CommonParameters>]
            #      -InstallationMediaPath<String>
            #      -ReplicationSourceDC<String>
            #      -SystemKey<SecureString>   Specifies the system key for the media from which you replicate the data. The default is none.
            #
            # Add specific parameters in case of a new DC in existing Domain

            Write-Host "About to Promote DC in an existing forest, existing domain, specify Credentials to join the existing domain"
            $JoinCred = Get-Credential -UserName "$($domXML.dnsname)\Administrator" -Message "Specify Credentials to join the existing domain"

            $ArgsDcPromo.Add("DomainName"       , $domXML.dnsname ) # "psdemo.com"
            $ArgsDcPromo.Add("Credential"       , $JoinCred       )
            $ArgsDcPromo.Add("SiteName"         , $SiteName       )

            # Optional Parameters..
            $ReplicationSourceDC = ($domxml.DCs.DC | Where-Object {$_.Name -eq $ComputerName } ).ReplicationSourceDC
            if ($ReplicationSourceDC) {
                Write-Verbose "Adding ReplicationSourceDC : $ReplicationSourceDC from optional parameter"
                $ArgsDcPromo.Add("ReplicationSourceDC"  , $ReplicationSourceDC )
            }

            Write-Host "About to Promote DC in an existing forest, existing domain, with the following parameters:"
            $ArgsDcPromo

            Test-ADDSDomainControllerInstallation  @ArgsDcPromo

            Install-ADDSDomainController @ArgsDcPromo

        } else {
            # Computername not found in DCs! Error, or update the XML file
            Write-Error "The current computername $ComputerName is NOT found in the DCs node in $XmlFile."
        }

    }
