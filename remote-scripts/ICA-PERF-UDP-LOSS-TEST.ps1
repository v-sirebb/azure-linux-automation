Import-Module .\TestLibs\RDFELibs.psm1 -Force
$result = ""
$testResult = ""
$resultArr = @()
$isDeployed = DeployVMS -setupType $currentTestData.setupType -Distro $Distro -xmlConfig $xmlConfig
if ($isDeployed)
{
	try
	{
		$noClient = $true
		$noServer = $true
		foreach ( $vmData in $allVMData )
		{
			if ( $vmData.RoleName -imatch "client" )
			{
				$clientVMData = $vmData
				$noClient = $false
			}
			elseif ( $vmData.RoleName -imatch "server" )
			{
				$noServer = $fase
				$serverVMData = $vmData
			}
		}
		if ( $noClient )
		{
			Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
		}
		if ( $noServer )
		{
			Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
		}
		#region CONFIGURE VM FOR TERASORT TEST
		LogMsg "CLIENT VM details :"
		LogMsg "  RoleName : $($clientVMData.RoleName)"
		LogMsg "  Public IP : $($clientVMData.InternalIP)"
		LogMsg "  SSH Port : $($clientVMData.SSHPort)"
		LogMsg "SERVER VM details :"
		LogMsg "  RoleName : $($serverVMData.RoleName)"
		LogMsg "  Public IP : $($serverVMData.InternalIP)"
		LogMsg "  SSH Port : $($serverVMData.SSHPort)"

		#
		# PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.	
		#
		ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"

		#endregion

		LogMsg "Generating constansts.sh ..."
		$constantsFile = "$LogDir\constants.sh"
		Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
		Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile	
		Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
		foreach ( $param in $currentTestData.TestParameters.param)
		{
			Add-Content -Value "$param" -Path $constantsFile
			if ($param -imatch "bufferLengths=")
			{
				$testBuffers= $param.Replace("bufferLenghs=(","").Replace(")","").Split(" ")
			}
			if ($param -imatch "connections=" )
			{
				$testConnections = $param.Replace("connections=(","").Replace(")","").Split(" ")
			}
		}
		LogMsg "constanst.sh created successfully..."
		LogMsg (Get-Content -Path $constantsFile)
		#endregion

		
		#region EXECUTE TEST
		$myString = @"
cd /root/
./perf_iperf3.sh &> iperf3udpConsoleLogs.txt
. azuremodules.sh
collect_VM_properties
"@
		Set-Content "$LogDir\Startiperf3udpTest.sh" $myString
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\remote-scripts\azuremodules.sh,.\remote-scripts\perf_iperf3.sh,.\$LogDir\Startiperf3udpTest.sh" -username "root" -password $password -upload
		RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files $currentTestData.files -username "root" -password $password -upload

		$out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
		$testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/Startiperf3udpTest.sh" -RunInBackground
		#endregion

		#region MONITOR TEST
		while ( (Get-Job -Id $testJob).State -eq "Running" )
		{
			$currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 iperf3udpConsoleLogs.txt"
			LogMsg "Current Test Staus : $currentStatus"
			WaitFor -seconds 20
		}
		$finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/iperf3udpConsoleLogs.txt"
		$iperf3LogDir = "$LogDir\iperf3Data"
		New-Item -itemtype directory -path $iperf3LogDir -Force -ErrorAction SilentlyContinue | Out-Null 
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-client-udp*"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-server-udp*"
		RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"

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

		function GetUDPDataObject()
		{
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

		foreach ( $Buffer in $testBuffers )
		{
			foreach ( $connection in $testConnections )
			{
				$currentResultObj = GetUDPDataObject

				$currentConnectionClientTxGbps = 0
				$currentConnectionClientTxGbpsArr = @()
				$currentConnectionClientUDPLoss = 0
				$currentConnectionClientUDPLossArr = @()

				$currentConnectionserverTxGbps = 0
				$currentConnectionserverTxGbpsArr = @()
				$currentConnectionserverUDPLoss = 0
				$currentConnectionserverUDPLossArr = @()

				foreach ( $file in $files )
				{
					#region Get Client data...
					if ( $file.Name -imatch "iperf-client-udp-IPv4-buffer-$($Buffer)K-conn-$connection-instance-*" )
					{
						$currentInstanceclientJsonText = $null
						$currentInstanceclientJsonObj = $null
						$currentInstanceClientPacketLoss = @()
						$currentInstanceClientThroughput = $null
						$fileName = $file.Name 
						try
						{
							$currentInstanceclientJsonText = ([string]( Get-Content "$clientfolder\$fileName")).Replace("-nan","0")
							$currentInstanceclientJsonObj = ConvertFrom-Json -InputObject $currentInstanceclientJsonText
						}
						catch 
						{
							LogErr "   $fileName : RETURNED NULL"
						}
						if ( $currentInstanceclientJsonObj.end.sum.lost_percent )
						{
							$currentConnectionClientUDPLossArr += $currentInstanceclientJsonObj.end.sum.lost_percent

							$currentConnCurrentInstanceAllIntervalThroughputArr = @()
							foreach ( $interval in $currentInstanceclientJsonObj.intervals )
							{
								$currentConnCurrentInstanceAllIntervalThroughputArr += $interval.sum.bits_per_second
							}
							$currentInstanceClientThroughput = (((($currentConnCurrentInstanceAllIntervalThroughputArr | Measure-Object -Average).Average))/1000000000)
							$outOfOrderPackats = ([regex]::Matches($currentInstanceclientJsonText, "OUT OF ORDER" )).count
							if ( $outOfOrderPackats -gt 0 )
							{
								LogErr "   $fileName : ERROR: $outOfOrderPackats PACKETS ARRIVED OUT OF ORDER"
							}
							LogMsg "    $fileName : Data collected successfully."
						}
						else
						{
							$currentInstanceClientThroughput = $null
							#Write-Host "    $($currentJsonObj.error) $currentFileClientThroughput "
						}
						if($currentInstanceClientThroughput)
						{
							$currentConnectionClientTxGbpsArr += $currentInstanceClientThroughput
						}
					}
					#endregion

					#region Get Server data...
					if ( $file.Name -imatch "iperf-server-udp-IPv4-buffer-$($Buffer)K-conn-$connection-instance-*" )
					{
						$currentInstanceserverJsonText = $null
						$currentInstanceserverJsonObj = $null
						$currentInstanceserverPacketLoss = @()
						$currentInstanceserverThroughput = $null
						$fileName = $file.Name 
						try
						{
							$currentInstanceserverJsonText = ([string]( Get-Content "$serverfolder\$fileName")).Replace("-nan","0")
							$currentInstanceserverJsonObj = ConvertFrom-Json -InputObject $currentInstanceserverJsonText
						}
						catch
						{
							LogErr "   $fileName : RETURNED NULL"
						}
						if ( $currentInstanceserverJsonObj.end.sum.lost_percent )
						{
							$currentConnectionserverUDPLossArr += $currentInstanceserverJsonObj.end.sum.lost_percent

							$currentConnCurrentInstanceAllIntervalThroughputArr = @()
							foreach ( $interval in $currentInstanceserverJsonObj.intervals )
							{
								$currentConnCurrentInstanceAllIntervalThroughputArr += $interval.sum.bits_per_second
							}
							$currentInstanceserverThroughput = (((($currentConnCurrentInstanceAllIntervalThroughputArr | Measure-Object -Average).Average))/1000000000)

							$outOfOrderPackats = ([regex]::Matches($currentInstanceserverJsonText, "OUT OF ORDER" )).count
							if ( $outOfOrderPackats -gt 0 )
							{
								LogErr "   $fileName : ERROR: $outOfOrderPackats PACKETS ARRIVED OUT OF ORDER"
							}
							LogMsg "    $fileName : Data collected successfully."
						}
						else
						{
							$currentInstanceserverThroughput = $null
							LogErr "   $fileName : $($currentInstanceserverJsonObj.error)"
						}
						if($currentInstanceserverThroughput)
						{
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
				$currentResultObj.BufferSize = $Buffer
				$currentResultObj.Connections = $connection
				$currentResultObj.ClientTxGbps = $currentConnectionClientTxGbps
				$currentResultObj.ClientUDPLoss = $currentConnectionClientUDPLoss
				if ( $currentConnectionClientTxGbps -ne 0 )
				{
					if ( $currentConnectionClientTxGbps -ge $currentConnectionserverTxGbps )
					{
						$currentResultObj.ThroughputDropPercent = [math]::Round(((($currentConnectionClientTxGbps-$currentConnectionserverTxGbps)*100)/$currentConnectionClientTxGbps),2)
					}
					else
					{
						$currentResultObj.ThroughputDropPercent = 0
					}
				}
				else
				{
					$currentResultObj.ThroughputDropPercent = 0
				}
				$currentResultObj.ServerRxGbps = $currentConnectionserverTxGbps
				$currentResultObj.ServerUDPLoss = $currentConnectionserverUDPLoss
				$FinalServerClientUDPResultObjArr += $currentResultObj
				Write-Host "-------------------------------"
			}
		}


		#endregion

		foreach ( $udpResultObject in $FinalServerClientUDPResultObjArr )
		{
			$connResult="ClientTxGbps=$($udpResultObject.ClientTxGbps) ServerRxGbps=$($udpResultObject.ServerRxGbps) UDPLoss=$($udpResultObject.ClientUDPLoss)%"
			$metaData = "Buffer=$($udpResultObject.BufferSize)K Connections=$($udpResultObject.Connections)"
			$resultSummary +=  CreateResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
		}
		if ( $finalStatus -imatch "TestFailed")
		{
			LogErr "Test failed. Last known status : $currentStatus."
			$testResult = "FAIL"
		}
		elseif ( $finalStatus -imatch "TestAborted")
		{
			LogErr "Test Aborted. Last known status : $currentStatus."
			$testResult = "ABORTED"
		}
		elseif ( $finalStatus -imatch "TestCompleted")
		{
			LogMsg "Test Completed."
			$testResult = "PASS"
		}
		elseif ( $finalStatus -imatch "TestRunning")
		{
			LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
			LogMsg "Contests of summary.log : $testSummary"
			$testResult = "PASS"
		}
		LogMsg "Test result : $testResult"
		LogMsg "Test Completed"
		
		
		LogMsg "Uploading the test results to DB STARTED.."
		$dataSource = $xmlConfig.config.Azure.database.server
		$dbuser = $xmlConfig.config.Azure.database.user
		$dbpassword = $xmlConfig.config.Azure.database.password
		$database = $xmlConfig.config.Azure.database.dbname
		$dataTableName = $xmlConfig.config.Azure.database.dbtable
		$TestCaseName = $xmlConfig.config.Azure.database.testTag
		if ($dataSource -And $dbuser -And $dbpassword -And $database -And $dataTableName) 
		{
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}						
			if ( $UseAzureResourceManager )
			{
				$HostType	= "Azure-ARM"
			}
			else
			{
				$HostType	= "Azure"
			}
			$HostBy	= ($xmlConfig.config.Azure.General.Location).Replace('"','')
			$HostOS	= cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
			$GuestOSType	= "Linux"
			$GuestDistro	= cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
			$GuestSize = $clientVMData.InstanceSize
			$KernelVersion	= cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
			$IPVersion = "IPv4"
			$ProtocolType = $($currentTestData.TestType)

			$connectionString = "Server=$dataSource;uid=$dbuser; pwd=$dbpassword;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
			$SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,IPVersion,ProtocolType,SendBufSize_KBytes,NumberOfConnections,TxThroughput_Gbps,RxThroughput_Gbps,DatagramLoss) VALUES "
			
			foreach ( $udpResultObject in $FinalServerClientUDPResultObjArr )
			{
				$SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$HostType','$HostBy','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','$IPVersion','UDP','$($udpResultObject.BufferSize)','$($udpResultObject.Connections)','$($udpResultObject.ClientTxGbps)','$($udpResultObject.ServerRxGbps)','$($udpResultObject.ClientUDPLoss)'),"
			}

			$SQLQuery = $SQLQuery.TrimEnd(',')
			LogMsg $SQLQuery
			$connection = New-Object System.Data.SqlClient.SqlConnection
			$connection.ConnectionString = $connectionString
			$connection.Open()

			$command = $connection.CreateCommand()
			$command.CommandText = $SQLQuery
			$result = $command.executenonquery()
			$connection.Close()
			LogMsg "Uploading the test results to DB DONE!!"
		}
		else
		{
			LogMsg "Invalid database details. Failed to upload result to database!"
		}
	}
	catch
	{
		$ErrorMessage =  $_.Exception.Message
		LogMsg "EXCEPTION : $ErrorMessage"   
	}
	Finally
	{
		$metaData = "iperf3udp RESULT"
		if (!$testResult)
		{
			$testResult = "Aborted"
		}
		$resultArr += $testResult
	}   
}

else
{
	$testResult = "Aborted"
	$resultArr += $testResult
}

$result = GetFinalResultHeader -resultarr $resultArr

#Clean up the setup
DoTestCleanUp -result $result -testName $currentTestData.testName -deployedServices $isDeployed -ResourceGroups $isDeployed

#Return the result and summery to the test suite script..
return $result, $resultSummary
