# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
param(
    [String] $TestParams
)

function Main {
    # Create test result
    $currentTestResult = Create-TestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        # role-0 vm is considered as the client-vm
        # role-1 vm is considered as the server-vm
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "role-0") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "role-1") {
                $noServer = $false
                $serverVMData = $vmData
            }
        }
        if ($noClient -or $noServer) {
            Throw "Client or Server VM not defined. Be sure that the SetupType has 2 VMs defined"
        }

        #region CONFIGURE VM FOR TERASORT TEST
        Write-LogInfo "CLIENT VM details :"
        Write-LogInfo "  RoleName : $($clientVMData.RoleName)"
        Write-LogInfo "  Public IP : $($clientVMData.InternalIP)"
        Write-LogInfo "  SSH Port : $($clientVMData.SSHPort)"
        Write-LogInfo "SERVER VM details :"
        Write-LogInfo "  RoleName : $($serverVMData.RoleName)"
        Write-LogInfo "  Public IP : $($serverVMData.InternalIP)"
        Write-LogInfo "  SSH Port : $($serverVMData.SSHPort)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        Write-LogInfo "Getting Active NIC Name."
        if ($TestPlatform -eq "Azure") {
            $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
            $clientNicName = (Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort `
                -username "root" -password $password -command $getNicCmd).Trim()
            $serverNicName = (Run-LinuxCmd -ip $serverVMData.PublicIP -port $serverVMData.SSHPort `
                -username "root" -password $password -command $getNicCmd).Trim()
        } elseif ($TestPlatform -eq "HyperV") {
            $clientNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $clientVMData.RoleName `
                $clientVMData.HypervHost $user $clientVMData.PublicIP $password $clientVMData.SSHPort
            $serverNicName = Get-GuestInterfaceByVSwitch $TestParams.PERF_NIC $serverVMData.RoleName `
                $serverVMData.HypervHost $user $serverVMData.PublicIP $password $serverVMData.SSHPort
        }
        if ( $serverNicName -eq $clientNicName) {
            Write-LogInfo "Server and client SRIOV NICs are the same."
        } else {
            Throw "Server and client SRIOV NICs are not same."
        }
        if($EnableAcceleratedNetworking -or ($currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV")) {
            $DataPath = "SRIOV"
        } else {
            $DataPath = "Synthetic"
        }
        Write-LogInfo "CLIENT $DataPath NIC: $clientNicName"
        Write-LogInfo "SERVER $DataPath NIC: $serverNicName"

        Write-LogInfo "Generating constants.sh ..."
        $constantsFile = "$LogDir\constants.sh"
        Set-Content -Value "#Generated by LISAv2 Automation" -Path $constantsFile
        Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile
        Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            if ($param -imatch "bufferLengths=") {
                $testBuffers= $param.Replace("bufferLengths=(","").Replace(")","").Split(" ")
            }
            if ($param -imatch "connections=" ) {
                $testConnections = $param.Replace("connections=(","").Replace(")","").Split(" ")
            }
        }
        Write-LogInfo "constants.sh created successfully..."
        Write-LogInfo (Get-Content -Path $constantsFile)
        #endregion

        #region EXECUTE TEST
        $myString = @"
cd /root/
./perf_iperf3.sh &> iperf3udpConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\Startiperf3udpTest.sh" $myString
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files "$constantsFile,$LogDir\Startiperf3udpTest.sh" -username "root" -password $password -upload
        Copy-RemoteFiles -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

        $null = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
        $testJob = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/Startiperf3udpTest.sh" -RunInBackground
        #endregion

        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 iperf3udpConsoleLogs.txt"
            Write-LogInfo "Current Test Status : $currentStatus"
            Wait-Time -seconds 20
        }
        $finalStatus = Run-LinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/iperf3udpConsoleLogs.txt"
        $iperf3LogDir = "$LogDir\iperf3Data"
        New-Item -itemtype directory -path $iperf3LogDir -Force -ErrorAction SilentlyContinue | Out-Null
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-client-udp*"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-server-udp*"
        Copy-RemoteFiles -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

        $testSummary = $null

        #region START UDP ANALYSIS
        $clientfolder = $iperf3LogDir
        $serverfolder = $iperf3LogDir

        #clientData
        $files = Get-ChildItem -Path $clientfolder
        $FinalClientThroughputArr=@()
        $FinalServerThroughputArr=@()
        $FinalClientUDPLossArr=@()
        $FinalServerUDPLossArr=@()
        $FinalServerClientUDPResultObjArr = @()

        function Get-UDPDataObject() {
            $objNode = New-Object -TypeName PSObject
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name BufferSize -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name Connections -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name ClientTxGbps -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name ServerRxGbps -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name ThroughputDropPercent -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name ClientUDPLoss -Value $null -Force
            Add-Member -InputObject $objNode -MemberType NoteProperty -Name ServerUDPLoss -Value $null -Force
            return $objNode
        }

        foreach ($Buffer in $testBuffers) {
            foreach ($connection in $testConnections) {
                $currentResultObj = Get-UDPDataObject

                $currentConnectionClientTxGbps = 0
                $currentConnectionClientTxGbpsArr = @()
                $currentConnectionClientUDPLoss = 0
                $currentConnectionClientUDPLossArr = @()

                $currentConnectionserverTxGbps = 0
                $currentConnectionserverTxGbpsArr = @()
                $currentConnectionserverUDPLoss = 0
                $currentConnectionserverUDPLossArr = @()

                foreach ($file in $files) {
                    #region Get Client data...
                    if ($file.Name -imatch "iperf-client-udp-IPv4-buffer-$($Buffer)-conn-$connection-instance-*") {
                        $currentInstanceclientJsonText = $null
                        $currentInstanceclientJsonObj = $null
                        $currentInstanceClientThroughput = $null
                        $fileName = $file.Name
                        try {
                            $currentInstanceclientJsonText = ([string]( Get-Content "$clientfolder\$fileName")).Replace("-nan","0")
                            $errorLines = (Select-String -Path $clientfolder\$fileName -Pattern "warning")
                            if ($errorLines) {
                                foreach ($errorLine in $errorLines)
                                {
                                    $currentInstanceclientJsonText = $currentInstanceclientJsonText.Replace($errorLine.Line,'')
                                }
                            }
                            $currentInstanceclientJsonObj = ConvertFrom-Json -InputObject $currentInstanceclientJsonText
                        } catch {
                            Write-LogErr " $fileName : RETURNED NULL"
                        }
                        if ($currentInstanceclientJsonObj.end.sum.lost_percent -or $currentInstanceserverJsonObj.end.sum.packets) {
                            $currentConnectionClientUDPLossArr += $currentInstanceclientJsonObj.end.sum.lost_percent

                            $currentConnCurrentInstanceAllIntervalThroughputArr = @()
                            foreach ($interval in $currentInstanceclientJsonObj.intervals) {
                                $currentConnCurrentInstanceAllIntervalThroughputArr += $interval.sum.bits_per_second
                            }
                            $currentInstanceClientThroughput = (((($currentConnCurrentInstanceAllIntervalThroughputArr | Measure-Object -Average).Average))/1000000000)
                            $outOfOrderPackats = ([regex]::Matches($currentInstanceclientJsonText, "OUT OF ORDER" )).count
                            if ($outOfOrderPackats -gt 0) {
                                Write-LogErr " $fileName : ERROR: $outOfOrderPackats PACKETS ARRIVED OUT OF ORDER"
                            }
                            Write-LogInfo " $fileName : Data collected successfully."
                        } else {
                            $currentInstanceClientThroughput = $null
                        }
                        if ($currentInstanceClientThroughput) {
                            $currentConnectionClientTxGbpsArr += $currentInstanceClientThroughput
                        }
                    }
                    #endregion

                    #region Get Server data...
                    if ($file.Name -imatch "iperf-server-udp-IPv4-buffer-$($Buffer)-conn-$connection-instance-*") {
                        $currentInstanceserverJsonText = $null
                        $currentInstanceserverJsonObj = $null
                        $currentInstanceserverThroughput = $null
                        $fileName = $file.Name
                        try {
                            $currentInstanceserverJsonText = ([string]( Get-Content "$serverfolder\$fileName")).Replace("-nan","0")
                            $currentInstanceserverJsonObj = ConvertFrom-Json -InputObject $currentInstanceserverJsonText
                        } catch {
                            Write-LogErr " $fileName : RETURNED NULL"
                        }
                        if ($currentInstanceserverJsonObj.end.sum.lost_percent -or $currentInstanceserverJsonObj.end.sum.packets) {
                            $currentConnectionserverUDPLossArr += $currentInstanceserverJsonObj.end.sum.lost_percent

                            $currentConnCurrentInstanceAllIntervalThroughputArr = @()
                            foreach ($interval in $currentInstanceserverJsonObj.intervals) {
                                $currentConnCurrentInstanceAllIntervalThroughputArr += $interval.sum.bits_per_second
                            }
                            $currentInstanceserverThroughput = (((($currentConnCurrentInstanceAllIntervalThroughputArr | Measure-Object -Average).Average))/1000000000)

                            $outOfOrderPackats = ([regex]::Matches($currentInstanceserverJsonText, "OUT OF ORDER" )).count
                            if ($outOfOrderPackats -gt 0) {
                                Write-LogErr " $fileName : ERROR: $outOfOrderPackats PACKETS ARRIVED OUT OF ORDER"
                            }
                            Write-LogInfo " $fileName : Data collected successfully."
                        } else {
                            $currentInstanceserverThroughput = $null
                            Write-LogErr "   $fileName : $($currentInstanceserverJsonObj.error)"
                        }
                        if ($currentInstanceserverThroughput) {
                            $currentConnectionserverTxGbpsArr += $currentInstanceserverThroughput
                        }
                    }
                    #endregion
                }

                $currentConnectionClientTxGbps = [math]::Round((($currentConnectionClientTxGbpsArr | Measure-Object -Average).Average),2)
                $currentConnectionClientUDPLoss = [math]::Round((($currentConnectionClientUDPLossArr | Measure-Object -Average).Average),2)
                Write-Host "Client: $Buffer . $connection . $currentConnectionClientTxGbps .$currentConnectionClientUDPLoss"
                $FinalClientThroughputArr += $currentConnectionClientTxGbps
                $FinalClientUDPLossArr += $currentConnectionClientUDPLoss

                $currentConnectionserverTxGbps = [math]::Round((($currentConnectionserverTxGbpsArr | Measure-Object -Average).Average),2)
                $currentConnectionserverUDPLoss = [math]::Round((($currentConnectionserverUDPLossArr | Measure-Object -Average).Average),2)
                Write-Host "Server: $Buffer . $connection . $currentConnectionserverTxGbps .$currentConnectionserverUDPLoss"
                $FinalServerThroughputArr += $currentConnectionserverTxGbps
                $FinalServerUDPLossArr += $currentConnectionserverUDPLoss
                $currentResultObj.BufferSize = $Buffer/1024
                $currentResultObj.Connections = $connection
                $currentResultObj.ClientTxGbps = $currentConnectionClientTxGbps
                $currentResultObj.ClientUDPLoss = $currentConnectionClientUDPLoss
                if ($currentConnectionClientTxGbps -ne 0) {
                    if ($currentConnectionClientTxGbps -ge $currentConnectionserverTxGbps) {
                        $currentResultObj.ThroughputDropPercent = [math]::Round(((($currentConnectionClientTxGbps-$currentConnectionserverTxGbps)*100)/$currentConnectionClientTxGbps),2)
                    } else {
                        $currentResultObj.ThroughputDropPercent = 0
                    }
                } else {
                    $currentResultObj.ThroughputDropPercent = 0
                }
                $currentResultObj.ServerRxGbps = $currentConnectionserverTxGbps
                $currentResultObj.ServerUDPLoss = $currentConnectionserverUDPLoss
                $FinalServerClientUDPResultObjArr += $currentResultObj
                Write-Host "-------------------------------"
            }
        }
        #endregion

        foreach ($udpResultObject in $FinalServerClientUDPResultObjArr) {
            $connResult="ClientTxGbps=$($udpResultObject.ClientTxGbps) ServerRxGbps=$($udpResultObject.ServerRxGbps) UDPLoss=$($udpResultObject.ClientUDPLoss)%"
            $metaData = "Buffer=$($udpResultObject.BufferSize)K Connections=$($udpResultObject.Connections)"
            $currentTestResult.TestSummary += Create-ResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }
        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            Write-LogInfo "Test Completed."
            $testResult = "PASS"
        }
        elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell background job is completed but VM is reporting that test is still running. Please check $LogDir\ConsoleLogs.txt"
            Write-LogInfo "Contents of summary.log : $testSummary"
            $testResult = "PASS"
        }
        Write-LogInfo "Test result : $testResult"
        Write-LogInfo "Test Completed"

        Write-LogInfo "Uploading the test results to DB STARTED.."
        $dataSource = $xmlConfig.config.$TestPlatform.database.server
        $dbuser = $xmlConfig.config.$TestPlatform.database.user
        $dbpassword = $xmlConfig.config.$TestPlatform.database.password
        $database = $xmlConfig.config.$TestPlatform.database.dbname
        $dataTableName = $xmlConfig.config.$TestPlatform.database.dbtable
        $TestCaseName = $xmlConfig.config.$TestPlatform.database.testTag
        if ($dataSource -And $dbuser -And $dbpassword -And $database -And $dataTableName) {
            $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
            $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
            $GuestOSType = "Linux"
            $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
            $GuestSize = $clientVMData.InstanceSize
            $KernelVersion = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
            $IPVersion = "IPv4"
            $ProtocolType = $($currentTestData.TestType)

            $SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,DataPath,SendBufSize_KBytes,NumberOfConnections,TxThroughput_Gbps,RxThroughput_Gbps,DatagramLoss) VALUES "

            foreach ($udpResultObject in $FinalServerClientUDPResultObjArr) {
                $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$TestPlatform','$TestLocation','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','$ProtocolType','$DataPath','$($udpResultObject.BufferSize)','$($udpResultObject.Connections)','$($udpResultObject.ClientTxGbps)','$($udpResultObject.ServerRxGbps)','$($udpResultObject.ClientUDPLoss)'),"
            }

            $SQLQuery = $SQLQuery.TrimEnd(',')
            Upload-TestResultToDatabase $SQLQuery
        } else {
            Write-LogInfo "Invalid database details. Failed to upload result to database!"
        }
    } catch {
        $ErrorMessage = $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogInfo "EXCEPTION : $ErrorMessage at line: $ErrorLine"
    } finally {
        $metaData = "iperf3udp RESULT"
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = Get-FinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult
}

Main -TestParams (ConvertFrom-StringData $TestParams.Replace(";","`n"))
