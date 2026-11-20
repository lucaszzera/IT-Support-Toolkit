#requires -Version 5.1
<#
.SYNOPSIS
  IT Support Toolkit V2 - Windows diagnostics, safe maintenance and HTML reporting.
.DESCRIPTION
  Read-only audit by default. Repairs are opt-in, backed up where applicable,
  logged, and limited to explicitly selected actions. No password/browser-history/
  personal-document cleanup is performed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit','Repair','InstallWeekly','UninstallWeekly')]
    [string]$Mode = 'Audit',
    [switch]$CreateRestorePoint,
    [switch]$FlushDns,
    [switch]$CleanTemp,
    [switch]$RestartSpooler,
    [switch]$RunDISM,
    [switch]$RunSFC,
    [int]$TempFileAgeDays = 7,
    [string]$OutputRoot = "$env:LOCALAPPDATA\ITSupportToolkit",
    [string]$TaskTime = '08:00'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$script:RunId = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Computer = $env:COMPUTERNAME
$script:RunRoot = Join-Path $OutputRoot $script:Computer
$script:ReportPath = Join-Path $script:RunRoot "ITSupport-$($script:Computer)-$($script:RunId).html"
$script:BackupRoot = Join-Path $script:RunRoot "Backups\$($script:RunId)"
$script:LogPath = Join-Path $script:RunRoot "ITSupport-$($script:RunId).log"
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Actions = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}
function Add-Finding {
    param([string]$Category,[string]$Status,[string]$Title,[string]$Detail,[string]$Recommendation='')
    $script:Findings.Add([pscustomobject]@{Category=$Category;Status=$Status;Title=$Title;Detail=$Detail;Recommendation=$Recommendation})
}
function Add-Action {
    param([string]$Name,[string]$Result,[string]$Detail='')
    $script:Actions.Add([pscustomobject]@{Time=(Get-Date);Name=$Name;Result=$Result;Detail=$Detail})
    Write-Log "$Name - $Result - $Detail"
}
function Test-IsAdmin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Ensure-Folders {
    foreach($p in @($script:RunRoot,$script:BackupRoot)) {
        if(-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}
function Save-ConfigurationBackup {
    Ensure-Folders
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    try {
        Get-CimInstance Win32_StartupCommand | Select-Object Name,Command,Location,User | Export-Csv (Join-Path $script:BackupRoot "Startup-$stamp.csv") -NoTypeInformation -Encoding UTF8
        Get-CimInstance Win32_Service | Select-Object Name,StartMode,State | Export-Csv (Join-Path $script:BackupRoot "Services-$stamp.csv") -NoTypeInformation -Encoding UTF8
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | Select-Object Description, DHCPEnabled,IPAddress,IPSubnet,DefaultIPGateway,DNSServerSearchOrder | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $script:BackupRoot "Network-$stamp.json") -Encoding UTF8
        foreach($key in @('HKCU\Software\Microsoft\Windows\CurrentVersion\Run','HKLM\Software\Microsoft\Windows\CurrentVersion\Run','HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
            $safe=($key -replace '[\\:]','_')
            & reg.exe export $key (Join-Path $script:BackupRoot "$safe-$stamp.reg") /y 2>$null | Out-Null
        }
        Add-Action 'Backup de configurações' 'OK' "Backup salvo em $script:BackupRoot"
        return $true
    } catch { Add-Action 'Backup de configurações' 'FALHA' $_.Exception.Message; return $false }
}
function Add-SystemFindings {
    # OS and device identity
    $os=Get-CimInstance Win32_OperatingSystem
    $cs=Get-CimInstance Win32_ComputerSystem
    Add-Finding 'Sistema' 'INFO' 'Sistema operacional' "$($os.Caption) | Build $($os.BuildNumber) | Último boot: $($os.LastBootUpTime)" 'Manter Windows e drivers atualizados.'
    Add-Finding 'Inventário' 'INFO' 'Equipamento' "$script:Computer | Fabricante: $($cs.Manufacturer) | Modelo: $($cs.Model) | Domínio/Workgroup: $($cs.Domain)" ''
    # Memory
    $total=[math]::Round($os.TotalVisibleMemorySize/1MB,2)
    $free=[math]::Round($os.FreePhysicalMemory/1MB,2)
    $usedPct=if($os.TotalVisibleMemorySize -gt 0){[math]::Round(100*(1-($os.FreePhysicalMemory/$os.TotalVisibleMemorySize)),1)}else{0}
    $status=if($usedPct -ge 90){'CRÍTICO'}elseif($usedPct -ge 80){'ATENÇÃO'}else{'OK'}
    Add-Finding 'Memória RAM' $status 'Uso de memória' "Total: $total GB | Livre: $free GB | Em uso: $usedPct%" 'Verificar processos com alto consumo e considerar expansão se a pressão for recorrente.'
    # CPU
    $cpu=Get-CimInstance Win32_Processor | Select-Object -First 1
    $load= if($cpu){[int]$cpu.LoadPercentage}else{-1}
    $cpuStatus=if($load -ge 90){'ATENÇÃO'}elseif($load -ge 0){'OK'}else{'NÃO VERIFICADO'}
    Add-Finding 'Processador' $cpuStatus 'Carga atual da CPU' $(if($load -ge 0){"Uso reportado: $load%"}else{'Não foi possível obter a carga.'}) 'Se a carga permanecer alta, identificar processos no Gerenciador de Tarefas.'
    # Disk volumes
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $freePct=if($_.Size -gt 0){[math]::Round(100*$_.FreeSpace/$_.Size,1)}else{0}
        $freeGB=[math]::Round($_.FreeSpace/1GB,1); $sizeGB=[math]::Round($_.Size/1GB,1)
        $s=if($freePct -lt 10){'CRÍTICO'}elseif($freePct -lt 20){'ATENÇÃO'}else{'OK'}
        Add-Finding 'Armazenamento' $s "Espaço livre em $($_.DeviceID)" "$freeGB GB livres de $sizeGB GB ($freePct%)." 'Liberar espaço com aprovação; não excluir arquivos pessoais.'
    }
    # Physical disk health (provider/driver dependent)
    try {
        $disks=Get-PhysicalDisk -ErrorAction Stop
        foreach($d in $disks){
            $health=[string]$d.HealthStatus; $op=[string]$d.OperationalStatus
            $s=if($health -notin @('Healthy','Unknown') -or $op -notmatch 'OK'){ 'ATENÇÃO' }elseif($health -eq 'Unknown'){'NÃO VERIFICADO'}else{'OK'}
            Add-Finding 'Disco físico' $s "Saúde reportada: $($d.FriendlyName)" "Tipo: $($d.MediaType) | Health: $health | Status: $op" 'Consultar ferramenta do fabricante e realizar backup imediato se houver alertas.'
        }
    } catch { Add-Finding 'Disco físico' 'NÃO VERIFICADO' 'SMART/saúde do disco' 'O provedor de armazenamento não disponibilizou dados de saúde.' 'Verificar com ferramenta do fabricante/BIOS; não interpretar ausência de dados como disco saudável.' }
    # Startup programs (inventory only)
    try {
        $startup=Get-CimInstance Win32_StartupCommand
        $count=@($startup).Count
        Add-Finding 'Inicialização' $(if($count -gt 15){'ATENÇÃO'}else{'INFO'}) 'Programas configurados para iniciar' "$count entradas encontradas. Lista detalhada no relatório." 'Revisar item a item com o usuário; não desativar automaticamente.'
        $script:StartupItems=@($startup | Select-Object Name,Command,Location,User)
    } catch { $script:StartupItems=@(); Add-Finding 'Inicialização' 'NÃO VERIFICADO' 'Programas de inicialização' $_.Exception.Message }
    # Audio/video PnP
    foreach($class in @('Camera','AudioEndpoint','Media')) {
        try {
            $dev=@(Get-PnpDevice -Class $class -PresentOnly -ErrorAction Stop)
            $bad=@($dev | Where-Object {$_.Status -ne 'OK'})
            $s=if($dev.Count -eq 0){'NÃO VERIFICADO'}elseif($bad.Count){'ATENÇÃO'}else{'OK'}
            Add-Finding 'Dispositivos' $s "Dispositivos $class" "$($dev.Count) encontrados; $($bad.Count) com status diferente de OK." 'Conferir conexão, driver, bloqueio físico e permissões de privacidade.'
        } catch { Add-Finding 'Dispositivos' 'NÃO VERIFICADO' "Dispositivos $class" 'Consulta PnP indisponível nesta versão/configuração do Windows.' }
    }
    # Privacy permissions - report only, do not change
    foreach($path in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam','HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone')) {
        $name=Split-Path $path -Leaf
        try { $v=(Get-ItemProperty -LiteralPath $path -Name Value -ErrorAction Stop).Value; Add-Finding 'Privacidade' 'INFO' "Permissão global: $name" "Valor registrado: $v" 'Verificar também permissões por aplicativo nas Configurações do Windows.' }
        catch { Add-Finding 'Privacidade' 'NÃO VERIFICADO' "Permissão global: $name" 'Não foi possível ler a configuração para o usuário atual.' }
    }
    # Network
    try {
        $cfg=Get-NetIPConfiguration | Where-Object {$_.IPv4DefaultGateway} | Select-Object -First 1
        if($cfg){
            $gw=$cfg.IPv4DefaultGateway.NextHop
            $ping=Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue
            Add-Finding 'Rede' $(if($ping){'OK'}else{'ATENÇÃO'}) 'Gateway padrão' "Gateway: $gw | Resposta ICMP: $ping" 'Se falhar, validar Wi-Fi/cabo, VLAN, DHCP e gateway.'
        } else { Add-Finding 'Rede' 'ATENÇÃO' 'Gateway padrão' 'Nenhum gateway IPv4 identificado.' 'Verificar conectividade e configuração IP.' }
        $dnsServers=@(Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object {$_.ServerAddresses} | ForEach-Object {$_.ServerAddresses} | Select-Object -Unique)
        $dnsOk=$false; try { Resolve-DnsName 'www.microsoft.com' -ErrorAction Stop | Out-Null; $dnsOk=$true } catch {}
        Add-Finding 'DNS' $(if($dnsOk){'OK'}else{'ATENÇÃO'}) 'Resolução DNS' "Teste www.microsoft.com: $dnsOk | Servidores: $($dnsServers -join ', ')" 'Validar DNS corporativo, VPN, proxy e disponibilidade do resolvedor.'
    } catch { Add-Finding 'Rede' 'NÃO VERIFICADO' 'Diagnóstico de rede' $_.Exception.Message }
    # Printer spooler and queue
    try {
        $sp=Get-Service Spooler -ErrorAction Stop
        $jobs=@(Get-CimInstance Win32_PrintJob -ErrorAction SilentlyContinue)
        $s=if($sp.Status -ne 'Running' -or $jobs.Count -gt 0){'ATENÇÃO'}else{'OK'}
        Add-Finding 'Impressão' $s 'Serviço e fila de impressão' "Spooler: $($sp.Status) | Trabalhos na fila: $($jobs.Count)" 'Conferir impressora e trabalhos antes de limpar a fila.'
        $script:PrintJobs=$jobs | Select-Object Name,Document,Owner,JobStatus
    } catch { $script:PrintJobs=@(); Add-Finding 'Impressão' 'NÃO VERIFICADO' 'Fila de impressão' $_.Exception.Message }
    # Recent critical system events (7 days)
    try {
        $since=(Get-Date).AddDays(-7)
        $events=@(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=$since;Level=1,2,3} -MaxEvents 150 -ErrorAction Stop | Where-Object {$_.ProviderName -match 'Kernel-Power|Disk|Ntfs|WHEA|BugCheck|volmgr'})
        Add-Finding 'Eventos' $(if($events.Count){'ATENÇÃO'}else{'OK'}) 'Eventos relevantes (últimos 7 dias)' "$($events.Count) eventos relacionados a energia, disco ou hardware." 'Correlacionar horário e Event ID com o relato do usuário; Kernel-Power 41 não identifica sozinho a causa.'
        $script:SystemEvents=@($events | Select-Object -First 30 TimeCreated,Id,ProviderName,LevelDisplayName,Message)
    } catch { $script:SystemEvents=@(); Add-Finding 'Eventos' 'NÃO VERIFICADO' 'Log de eventos' 'Não foi possível consultar o log System.' }
}
function Invoke-SafeRepairs {
    if(-not (Test-IsAdmin)){ throw 'O modo Repair exige PowerShell elevado como Administrador.' }
    if(-not (Save-ConfigurationBackup)){ throw 'Backup de configurações falhou. Manutenção cancelada.' }
    if($CreateRestorePoint){
        try {
            Checkpoint-Computer -Description "ITSupportToolkit-$script:RunId" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
            Add-Action 'Ponto de restauração' 'OK' 'Ponto solicitado ao Windows.'
        } catch { Add-Action 'Ponto de restauração' 'NÃO DISPONÍVEL' $_.Exception.Message }
    }
    if($FlushDns){ try { Clear-DnsClientCache; Add-Action 'Limpeza de cache DNS' 'OK' 'Cache DNS local limpo.' } catch { Add-Action 'Limpeza de cache DNS' 'FALHA' $_.Exception.Message } }
    if($RestartSpooler){
        try { Restart-Service Spooler -Force -ErrorAction Stop; Add-Action 'Reiniciar spooler' 'OK' 'Serviço reiniciado; trabalhos da fila não foram apagados.' }
        catch { Add-Action 'Reiniciar spooler' 'FALHA' $_.Exception.Message }
    }
    if($CleanTemp){
        $cutoff=(Get-Date).AddDays(-[math]::Abs($TempFileAgeDays)); $removed=0; $skipped=0
        $paths=@("$env:TEMP","$env:WINDIR\Temp") | Select-Object -Unique
        foreach($path in $paths){
            if(Test-Path -LiteralPath $path){
                Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {$_.LastWriteTime -lt $cutoff} | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; $removed++ } catch { $skipped++ }
                }
            }
        }
        Add-Action 'Limpeza de temporários' 'CONCLUÍDO' "$removed arquivos antigos removidos; $skipped ignorados/bloqueados. Pastas pessoais não foram tocadas."
    }
    if($RunDISM){
        try { $p=Start-Process dism.exe -ArgumentList '/Online','/Cleanup-Image','/RestoreHealth' -Wait -PassThru -NoNewWindow; Add-Action 'DISM RestoreHealth' $(if($p.ExitCode -eq 0){'OK'}else{'CÓDIGO '+$p.ExitCode}) 'Pode levar vários minutos.' }
        catch { Add-Action 'DISM RestoreHealth' 'FALHA' $_.Exception.Message }
    }
    if($RunSFC){
        try { $p=Start-Process sfc.exe -ArgumentList '/scannow' -Wait -PassThru -NoNewWindow; Add-Action 'SFC Scannow' $(if($p.ExitCode -eq 0){'OK'}else{'CÓDIGO '+$p.ExitCode}) 'Consultar CBS.log se houver reparos ou falhas.' }
        catch { Add-Action 'SFC Scannow' 'FALHA' $_.Exception.Message }
    }
    if(-not ($CreateRestorePoint -or $FlushDns -or $CleanTemp -or $RestartSpooler -or $RunDISM -or $RunSFC)) {
        Add-Action 'Manutenção' 'SEM ALTERAÇÕES' 'Nenhuma ação de reparo foi selecionada.'
    }
}
function ConvertTo-HtmlSafe([object]$Value) { return [System.Net.WebUtility]::HtmlEncode([string]$Value) }
function New-HtmlReport {
    Ensure-Folders
    $findRows=foreach($f in $script:Findings){
        $cls=switch($f.Status){'CRÍTICO'{'critical'}'ATENÇÃO'{'warning'}'OK'{'ok'}default{'info'}}
        "<tr><td>$(ConvertTo-HtmlSafe $f.Category)</td><td><span class='pill $cls'>$(ConvertTo-HtmlSafe $f.Status)</span></td><td>$(ConvertTo-HtmlSafe $f.Title)</td><td>$(ConvertTo-HtmlSafe $f.Detail)</td><td>$(ConvertTo-HtmlSafe $f.Recommendation)</td></tr>"
    }
    $startupRows=foreach($s in @($script:StartupItems)){"<tr><td>$(ConvertTo-HtmlSafe $s.Name)</td><td>$(ConvertTo-HtmlSafe $s.User)</td><td>$(ConvertTo-HtmlSafe $s.Location)</td><td>$(ConvertTo-HtmlSafe $s.Command)</td></tr>"}
    $actionRows=foreach($a in $script:Actions){"<tr><td>$($a.Time.ToString('yyyy-MM-dd HH:mm:ss'))</td><td>$(ConvertTo-HtmlSafe $a.Name)</td><td>$(ConvertTo-HtmlSafe $a.Result)</td><td>$(ConvertTo-HtmlSafe $a.Detail)</td></tr>"}
    $eventRows=foreach($e in @($script:SystemEvents)){"<tr><td>$($e.TimeCreated)</td><td>$($e.Id)</td><td>$(ConvertTo-HtmlSafe $e.ProviderName)</td><td>$(ConvertTo-HtmlSafe $e.Message)</td></tr>"}
    $printRows=foreach($j in @($script:PrintJobs)){"<tr><td>$(ConvertTo-HtmlSafe $j.Name)</td><td>$(ConvertTo-HtmlSafe $j.Document)</td><td>$(ConvertTo-HtmlSafe $j.Owner)</td></tr>"}
    $counts=($script:Findings | Group-Object Status -AsHashTable -AsString)
    $html=@"
<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>IT Support Toolkit - $script:Computer</title>
<style>
:root{--bg:#f3f6fb;--card:#fff;--ink:#172033;--muted:#65728a;--line:#e3e9f2;--blue:#2457c5}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 Segoe UI,Arial,sans-serif}.wrap{max-width:1200px;margin:28px auto;padding:0 18px}.hero{background:linear-gradient(120deg,#14213d,#2457c5);color:white;padding:28px;border-radius:16px}.hero h1{margin:0 0 6px;font-size:26px}.meta{opacity:.85}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin:16px 0}.metric,.panel{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}.metric b{display:block;font-size:25px}.metric span{color:var(--muted)}h2{font-size:18px;margin:24px 0 10px}table{width:100%;border-collapse:collapse;background:white;font-size:13px}th,td{text-align:left;padding:10px;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:anywhere}th{background:#f7f9fc;color:#45516a}.pill{display:inline-block;padding:3px 8px;border-radius:30px;font-weight:600;font-size:11px}.ok{background:#e5f7ec;color:#17683a}.warning{background:#fff3d6;color:#885600}.critical{background:#ffe4e4;color:#a51e1e}.info{background:#e9efff;color:#244a9a}.note{color:var(--muted);font-size:12px}.tablebox{overflow:auto;border-radius:10px;border:1px solid var(--line)}footer{margin:22px 0;color:var(--muted);font-size:12px}@media(max-width:800px){.grid{grid-template-columns:repeat(2,1fr)}}
</style></head><body><div class="wrap"><header class="hero"><h1>IT Support Toolkit</h1><div>Relatório de diagnóstico e manutenção Windows</div><p class="meta">Equipamento: $script:Computer | Execução: $script:RunId | Usuário: $(ConvertTo-HtmlSafe "$env:USERDOMAIN\$env:USERNAME")</p></header>
<div class="grid"><div class="metric"><b>$($script:Findings.Count)</b><span>Verificações/achados</span></div><div class="metric"><b>$(if($counts.ContainsKey('CRÍTICO')){$counts['CRÍTICO'].Count}else{0})</b><span>Críticos</span></div><div class="metric"><b>$(if($counts.ContainsKey('ATENÇÃO')){$counts['ATENÇÃO'].Count}else{0})</b><span>Atenção</span></div><div class="metric"><b>$($script:Actions.Count)</b><span>Ações registradas</span></div></div>
<h2>Resumo do diagnóstico</h2><div class="tablebox"><table><thead><tr><th>Categoria</th><th>Status</th><th>Verificação</th><th>Resultado</th><th>Recomendação</th></tr></thead><tbody>$($findRows -join "`n")</tbody></table></div>
<h2>Programas na inicialização (somente inventário)</h2><div class="tablebox"><table><thead><tr><th>Nome</th><th>Usuário</th><th>Origem</th><th>Comando</th></tr></thead><tbody>$($startupRows -join "`n")</tbody></table></div>
<h2>Fila de impressão</h2><div class="tablebox"><table><thead><tr><th>Trabalho</th><th>Documento</th><th>Proprietário</th></tr></thead><tbody>$($printRows -join "`n")</tbody></table></div>
<h2>Eventos relevantes do sistema (até 30)</h2><div class="tablebox"><table><thead><tr><th>Data</th><th>ID</th><th>Origem</th><th>Mensagem</th></tr></thead><tbody>$($eventRows -join "`n")</tbody></table></div>
<h2>Ações executadas</h2><div class="tablebox"><table><thead><tr><th>Data</th><th>Ação</th><th>Resultado</th><th>Detalhes</th></tr></thead><tbody>$($actionRows -join "`n")</tbody></table></div>
<footer>Gerado localmente pelo IT Support Toolkit V2. Relatório técnico; validar achados antes de executar alterações. Dados coletados devem ser tratados conforme as políticas de privacidade da organização.</footer></div></body></html>
"@
    Set-Content -LiteralPath $script:ReportPath -Value $html -Encoding UTF8
    Add-Action 'Relatório HTML' 'OK' $script:ReportPath
}
function Install-WeeklyTask {
    if(-not (Test-IsAdmin)){throw 'A instalação da tarefa agendada exige PowerShell como Administrador.'}
    $scriptPath=$PSCommandPath
    if(-not $scriptPath){throw 'Salve o script ITSupportToolkit.ps1 em uma pasta permanente antes de instalar a tarefa.'}
    $time= [datetime]::ParseExact($TaskTime,'HH:mm',$null)
    $action=New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Audit"
    $trigger=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At $time
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'ITSupportToolkit-WeeklyAudit' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Auditoria semanal do IT Support Toolkit. Somente leitura.' -Force | Out-Null
    Write-Host "Tarefa instalada: segunda-feira às $TaskTime. Ela executa somente auditoria." -ForegroundColor Green
}
function Uninstall-WeeklyTask {
    if(-not (Test-IsAdmin)){throw 'A remoção da tarefa agendada exige PowerShell como Administrador.'}
    Unregister-ScheduledTask -TaskName 'ITSupportToolkit-WeeklyAudit' -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Tarefa semanal removida (se existia).' -ForegroundColor Green
}

try {
    Ensure-Folders
    Write-Log "Início - modo $Mode"
    switch($Mode){
        'Audit' { Add-SystemFindings; New-HtmlReport; Write-Host "Relatório criado: $script:ReportPath" -ForegroundColor Green }
        'Repair' { Add-SystemFindings; Invoke-SafeRepairs; $script:Findings.Clear(); Add-SystemFindings; New-HtmlReport; Write-Host "Relatório criado: $script:ReportPath" -ForegroundColor Green }
        'InstallWeekly' { Install-WeeklyTask }
        'UninstallWeekly' { Uninstall-WeeklyTask }
    }
    Write-Log 'Fim da execução.'
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Error $_
    exit 1
}
