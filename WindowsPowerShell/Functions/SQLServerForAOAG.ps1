
function Install-SqlServerForAOAG {
    param (
        # Path to folder where msi files for additional SQL features are located
        [String] $SetupRoot = '',

        # Path to folder where msi files for additional SQLPS module are located
        [String] $SqlpsSetupRoot = '',

        [String] $MuranoFileShare = '',

        # (REQUIRED) Domain name
        [String] $SQLServiceUserDomain = 'fc-acme.local',

        # (REQUIRED) User name for the account which will be used by SQL service
        [String] $SQLServiceUserName = 'Administrator',

        # (REQUIRED) Password for that user
        [String] $SQLServiceUserPassword = 'P@ssw0rd',

        [Switch] $UpdateEnabled
    )


    if ($MuranoFileShare -eq '') {
        $MuranoFileShare = [Environment]::GetEnvironmentVariable('MuranoFileShare')
        if ($MuranoFileShare -eq '') {
            throw("Unable to find MuranoFileShare path.")
        }
    }

    if ($SetupRoot -eq '') {
        $SetupRoot = [IO.Path]::Combine($MuranoFileShare, 'Prerequisites\SQL Server\2012')
    }

    if ($SqlpsSetupRoot -eq '') {
        $SqlpsSetupRoot = [IO.Path]::Combine($MuranoFileShare, 'Prerequisites\SQL Server\Tools')
    }

    $ExtraOptions = @{}

    if ($UpdateEnabled) {
        $ExtraOptions += @{'UpdateEnabled' = $true}
    }
    else {
        $ExtraOptions += @{'UpdateEnabled' = $false}
    }

    New-SQLServerForAOAG `
        -SetupRoot $SetupRoot `
        -SQLSvcUsrDomain $SQLServiceUserDomain `
        -SQLSvcUsrName $SQLServiceUserName `
        -SQLSvcUsrPassword $SQLServiceUserPassword `
        -ExtraOptions $ExtraOptions

    Install-SqlServerPowerShellModule -SetupRoot $SqlpsSetupRoot
}



function Initialize-AlwaysOnAvailabilityGroup {
    param (
        [String] $DomainName,
        [String] $DomainAdminAccountName,
        [String] $DomainAdminAccountPassword,
        [String] $SqlServiceAccountName,
        [String] $PrimaryNode,
        [String] $ShareName = 'SharedWorkDir'
    )

    $ShareNetworkPath = '\\' + $PrimaryNode + '\' + $ShareName

    $DomainAdminAccountCreds = New-Credential `
        -UserName "$DomainName\$DomainAdminAccountName" `
        -Password "$DomainAdminAccountPassword"

    $FunctionsFile = Export-Function 'Get-NextFreePort', 'Initialize-AlwaysOn'

    Start-PowerShellProcess @"
trap {
    `$_
    exit 1
}

Import-Module CoreFunctions

Write-Log "Importing functions file '$FunctionsFile' ..."
. "$FunctionsFile"

Write-Log "Starting 'Initialize-AlwaysOn' ..."
`$XmlFile = [IO.Path]::Combine("$ShareNetworkPath", "`$(`$Env:ComputerName).xml")
Write-Log "Output XML file is '`$XmlFile'"
Initialize-AlwaysOn | Export-CliXml -Path `$XmlFile
"@ -Credential $DomainAdminAccountCreds -NoBase64

}


function New-SharedFolderForAOAG {
    param (
        # (OPTIONAL)
        [String] $SharePath = [IO.Path]::Combine($Env:SystemDrive + '\', 'SharedWorkDir'),

        # (OPTIONAL)
        [String] $ShareName = 'SharedWorkDir'
    )

    if ($ShareName -eq '') {
        $ShareName = [IO.Path]::GetFileNameWithoutExtension($SharePath)
    }

    Write-LogDebug "SharePath = '$SharePath'"
    Write-LogDebug "ShareName = '$ShareName'"

    try {
        Write-LogDebug "Trying to remove share '$ShareName'"
        $null = Get-SmbShare -Name $ShareName -ErrorAction 'Stop'
        Remove-SmbShare -Name $ShareName -Force
        write-Log "Share '$ShareName' removed."
    }
    catch {
        Write-LogWarning "Share '$ShareName' not exists or cannot be deleted."
    }

    try {
        Write-LogDebug "Trying to remove folder '$SharePath"
        $null = Get-Item -Path $SharePath -ErrorAction 'Stop'
        Remove-Item -Path $SharePath -Recurse -Force
        Write-Log "Folder '$SharePath' removed."
    }
    catch {
        Write-LogWarning "Folder '$SharePath' not exists or cannot be deleted."
    }

    $null = New-Item -Path $SharePath -ItemType Container -Force
            
    $null = New-SmbShare -Path $SharePath `
        -Name $ShareName `
        -FullAccess "Everyone" `
        -Description "Shared folder for AlwaysOn Availability Group setup."

    return '\\' + $Env:ComputerName + '\' + $ShareName
}



function New-DatabaseForAOAG {
    param (
        [String] $DatabaseName,
        [String] $DomainName,
        [String] $UserName,
        [String] $UserPassword
    )

    $Creds = New-Credential -UserName "$DomainName\$UserName" -Password "$UserPassword"

    $FunctionsFile = Export-Function 'Invoke-SQLText', 'ConvertTo-SQLName', 'ConvertTo-SQLString', 'New-SQLDatabase'

    Start-PowerShellProcess @"
trap {
    `$_
    exit 1
}

Import-Module CoreFunctions

Write-Log "Importing functions from file '$FunctionsFile' ..."
. "$FunctionsFile"

Write-Log "Starting 'New-SQLDatabase' ..."
New-SQLDatabase $DatabaseName
"@ -Credential $Creds -NoBase64
}



function Initialize-AOAGPrimaryReplica {
    param (
        # (OPTIONAL) Name of the new Availability Group. If not specified then default name will be used.
        [String] $GroupName = 'MuranoAvailabilityGroup',

        # (REQUIRED) Nodes that will be configured as replica partners.
        #[Parameter(Mandatory=$true)]
        [String[]] $NodeList,

        # (REQUIRED) Node name that will be primary for selected Availability Group
        #[Parameter(Mandatory=$true)]
        [String] $PrimaryNode,

        # (REQUIRED) Database list that will be added to the Availability Group
        #[Parameter(Mandatory=$true)]
        [String[]] $DatabaseList,

        # (REQUIRED) Listener name that will be used by clients to connect to databases in that AG
        #[Parameter(Mandatory=$true)]
        [String] $ListenerName,

        # (REQUIRED) IP address of the listener
        #[Parameter(Mandatory=$true)]
        [String] $ListenerIP,

        [String] $ListenerIPMask = '255.255.255.0',

        [String] $ListenerPort = '5023',

        # Sync Mode Node List
        [String[]] $SyncModeNodeList,

        [String] $SharedWorkDir = 'SharedWorkDir',

        [String] $CliXmlFile = '',

        [String] $DomainName,
        [String] $UserName,
        [String] $UserPassword
    )

    if ($PrimaryNode.ToLower() -ne ($Env:ComputerName).ToLower()) {
        Write-Log "This function works on PrimaryNode only."
        Write-Log "Exiting."
        return
    }

    if ($CliXmlFile -eq '') {
        $ReplicaDefinitionList = @()
        foreach ($Node in $NodeList) {
            try {
                $NodeEndpointPort = Import-CliXml -Path "\\$PrimaryNode\SharedWorkDir\$Node.xml"
            }
            catch {
                $NodeEndpointPort = 5022
            }

            $ReplicaDefinition = @{
                "SERVER_INSTANCE" = "$Node";
                "ENDPOINT_URL" = "TCP://${Node}:${NodeEndpointPort}";
                "AVAILABILITY_MODE" = "ASYNCHRONOUS_COMMIT";
                "FAILOVER_MODE"="MANUAL";
            }

            if ($SyncModeNodeList -contains $Node) {
                $ReplicaDefinition['AVAILABILITY_MODE'] = "SYNCHRONOUS_COMMIT"
                $ReplicaDefinition['FAILOVER_MODE'] = "AUTOMATIC"
            }

            $ReplicaDefinitionList += @($ReplicaDefinition)
        }

        $Preferences = @{}

        $ListenerDefinition = @{
            "NAME"=$ListenerName;
            "PORT" = "$ListenerPort";
            "STATIC" = "$ListenerIP/$ListenerIPMask"
        }

        $Parameters = @{
            'WorkDir' = "\\$PrimaryNode\$SharedWorkDir";
            'Name' = $GroupName;
            'DatabaseNames' = $DatabaseList;
            'ReplicaDefs' = $ReplicaDefinitionList;
            'Preferences' = $Preferences;
            'ListenerDef' = $ListenerDefinition;
        }

        Remove-Item -Path "\\$PrimaryNode\SharedWorkDir\*" -Force

        $CliXmlFile = [IO.Path]::GetTempFileName()

        Export-CliXml -Path $CliXmlFile -InputObject $Parameters -Depth 10

        Initialize-AOAGPrimaryReplica `
            -CliXmlFile $CliXmlFile `
            -DomainName $DomainName `
            -UserName $UserName `
            -UserPassword $UserPassword
    }
    else {
        $Creds = New-Credential -UserName "$DomainName\$UserName" -Password "$UserPassword"

        $FunctionsFile = Export-Function -All

        Start-PowerShellProcess @"
trap {
    `$_
    exit 1
}

Import-Module CoreFunctions

Write-Log "Importing functions from '$FunctionsFile' ..."
. "$FunctionsFile"

Write-Log "Importing CliXml parameters file ..."
`$Parameters = Import-CliXml -Path $CliXmlFile

Write-Log "Starting 'New-AlwaysOnAvailabilityGroup' ..."
New-AlwaysOnAvailabilityGroup ``
    -WorkDir `$Parameters['WorkDir'] ``
    -Name `$Parameters['Name'] ``
    -DatabaseNames `$Parameters['DatabaseNames'] ``
    -ReplicaDefs `$Parameters['ReplicaDefs'] ``
    -Preferences `$Parameters['Preferences'] ``
    -ListenerDef `$Parameters['ListenerDef']
"@ -Credential $Creds -NoBase64

    }
}



function Initialize-AOAGSecondaryReplica {
    param (
        # (REQUIRED) Nodes that will be configured as replica partners.
        [Parameter(Mandatory=$true)]
        [String[]] $NodeList,

        # (REQUIRED) Node name that will be primary for selected Availability Group
        [Parameter(Mandatory=$true)]
        [String] $PrimaryNode,

        [String] $SharedWorkDir = 'SharedWorkDir',

        [String] $DomainName,
        [String] $UserName,
        [String] $UserPassword
    ) 

    if ($PrimaryNode.ToLower() -eq ($Env:ComputerName).ToLower()) {
        Write-Log "This function works on any SecondaryNode only."
        Write-Log "Exiting."
        return
    }

    $Creds = New-Credential -UserName "$DomainName\$UserName" -Password "$UserPassword"

    $FunctionsFile = Export-Function -All

    Start-PowerShellProcess @"
trap {
    $_
    exit 1
}

Import-Module CoreFunctions

Write-Log "Importing functions from '$FunctionsFile' ..."
. "$FunctionsFile"

Write-Log "Starting 'New-AlwaysOnAvailabilityGroupReplica' ..."
New-AlwaysOnAvailabilityGroupReplica -WorkDir "\\$PrimaryNode\$SharedWorkDir"
"@ -Credential $Creds -NoBase64
}

