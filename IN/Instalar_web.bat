@echo off
setlocal disabledelayedexpansion
title Instalador de Mods (web) - Cliente
color 0A
echo ======================================
echo    INSTALADOR DE MODS POR INTERNET
echo ======================================
echo.
echo Instala o actualiza los mods en tu carpeta de Minecraft.
echo Solo descarga lo nuevo o lo que cambio y borra lo que sobra.
echo.
set "DEST=%appdata%\.minecraft\mods"
set "F0=%~f0"
set "F0=%F0:'=''%"
set "DP=%DEST:'=''%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=Get-Content -Raw -LiteralPath '%F0%'; $i=$t.LastIndexOf('#PS1START'); $s=$t.Substring($i); & ([scriptblock]::Create($s)) -Dest '%DP%'"
echo.
pause
exit /b
#PS1START
param([string]$Dest)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ================= CONFIGURACION =================
$Repo    = 'Zilv24/Minecraft-Server'
$Carpeta = 'M'
$Rama    = 'main'
# Mods grandes que no caben en GitHub (mas de 25 MB): nombre = ID del archivo en Drive
$Drive = [ordered]@{
    '1.jar' = '19YbZmGUztFfWs6NiywRj7Zmjl_Zh1dHz'
    '3.jar' = '1Wnb3JFHShLIp07PBBTy4xrqO7F_q5dTu'
}
# Tamano esperado (minimo, maximo) para detectar si se cruzaron los dos ID
$TamDrive = @{ '1.jar' = @(30MB, 40MB); '3.jar' = @(75MB, 90MB) }
# Si cambias un mod grande en Drive, sube este numero para que se vuelva a descargar
$VersionDrive = '1'
# =================================================

function Sha-Git([string]$p) {
    $b = [IO.File]::ReadAllBytes($p)
    $h = [Text.Encoding]::ASCII.GetBytes('blob ' + $b.Length + [char]0)
    $all = New-Object byte[] ($h.Length + $b.Length)
    [Array]::Copy($h, 0, $all, 0, $h.Length)
    [Array]::Copy($b, 0, $all, $h.Length, $b.Length)
    $s = [Security.Cryptography.SHA1]::Create()
    return (($s.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Es-Jar([string]$p) {
    $f = [IO.File]::OpenRead($p)
    try { $a = $f.ReadByte(); $c = $f.ReadByte(); return ($a -eq 80 -and $c -eq 75) } finally { $f.Close() }
}
function Bajar([string]$url, [string]$out, [string]$etq) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = 'mods-installer'
    $req.AllowAutoRedirect = $true
    $req.CookieContainer = New-Object Net.CookieContainer
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 60000
    $resp = $req.GetResponse()
    $tot = $resp.ContentLength
    $in = $resp.GetResponseStream()
    $fs = [IO.File]::Create($out)
    try {
        $buf = New-Object byte[] 81920
        $got = 0L
        $ult = [DateTime]::MinValue
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $got += $n
            if (([DateTime]::Now - $ult).TotalMilliseconds -gt 250) {
                Dibujar $etq $got $tot
                $ult = [DateTime]::Now
            }
        }
        Dibujar $etq $got $tot
        Write-Host ''
    } finally {
        $fs.Close(); $in.Close(); $resp.Close()
    }
}
function Dibujar([string]$etq, [long]$got, [long]$tot) {
    $mb = $got / 1MB
    if ($tot -gt 0) {
        $f = [Math]::Min(1.0, $got / $tot)
        $l = [int][Math]::Floor($f * 20)
        $barra = ('#' * $l) + ('-' * (20 - $l))
        $txt = '{0}  [{1}] {2,3}%  {3:N1}/{4:N1} MB' -f $etq, $barra, [int]($f * 100), $mb, ($tot / 1MB)
    } else {
        $txt = '{0}  {1:N1} MB' -f $etq, $mb
    }
    Write-Host ("`r" + $txt + '   ') -NoNewline
}

Write-Host 'Consultando la lista de mods en GitHub...'
$uri = 'https://api.github.com/repos/' + $Repo + '/contents/' + $Carpeta + '?ref=' + $Rama
$items = @()
try {
    $items = @(Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'mods-installer'; 'Accept' = 'application/vnd.github+json' })
} catch {
    Write-Host 'No se pudo leer GitHub. Revisa tu internet y que el repositorio sea publico.'
    Write-Host $_.Exception.Message
    exit
}
$remoto = [ordered]@{}
foreach ($x in $items) {
    foreach ($it in @($x)) {
        if ($it.type -eq 'file' -and ([string]$it.name) -like '*.jar') { $remoto[[string]$it.name] = $it }
    }
}
if ($remoto.Count -eq 0) { Write-Host 'GitHub no devolvio ningun .jar. No se hizo nada.'; exit }

if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest | Out-Null }
$estadoPath = Join-Path (Split-Path $Dest -Parent) 'mods_estado_drive.txt'
$estado = @{}
if (Test-Path -LiteralPath $estadoPath) {
    foreach ($l in Get-Content -LiteralPath $estadoPath) {
        $q = $l.Split('|')
        if ($q.Count -ge 2) { $estado[$q[0]] = $q[1] }
    }
}

$conservar = @{}
$bajar = @()
$faltaDrive = @()
foreach ($n in $remoto.Keys) {
    $it = $remoto[$n]
    $conservar[$n] = $true
    $lp = Join-Path $Dest $n
    $hace = $false
    if (-not (Test-Path -LiteralPath $lp)) { $hace = $true }
    elseif ((Sha-Git $lp) -ne $it.sha) { $hace = $true }
    if ($hace) {
        $bajar += [pscustomobject]@{ Nombre = $n; Url = $it.download_url; Origen = 'GitHub'; Sha = $it.sha; Clave = '' }
    }
}
foreach ($n in $Drive.Keys) {
    $id = $Drive[$n]
    $conservar[$n] = $true
    $lp = Join-Path $Dest $n
    if ($id -like 'PEGA_AQUI*') {
        if (-not (Test-Path -LiteralPath $lp)) { $faltaDrive += $n }
        continue
    }
    $clave = $id + '_v' + $VersionDrive
    if ((-not (Test-Path -LiteralPath $lp)) -or ($estado[$n] -ne $clave)) {
        $url = 'https://drive.usercontent.google.com/download?id=' + $id + '&export=download&confirm=t'
        $bajar += [pscustomobject]@{ Nombre = $n; Url = $url; Origen = 'Drive'; Sha = ''; Clave = $clave }
    }
}
$extras = @(Get-ChildItem -LiteralPath $Dest -File -Force | Where-Object { -not $conservar.ContainsKey($_.Name) })

$sinCambio = $conservar.Count - $bajar.Count - $faltaDrive.Count
Write-Host ''
Write-Host ('Mods en el paquete       : ' + $conservar.Count)
Write-Host ('Sin cambios              : ' + $sinCambio)
Write-Host ('Por descargar (nuevos o cambiados): ' + $bajar.Count)
Write-Host ('Por borrar (no son del paquete)   : ' + $extras.Count)
if ($faltaDrive.Count -gt 0) {
    Write-Host ('AVISO: faltan los ID de Drive de: ' + ($faltaDrive -join ', ') + ' (no se instalaran)')
}
if ($bajar.Count -eq 0 -and $extras.Count -eq 0) {
    Write-Host ''
    Write-Host 'Todo esta al dia. No hay nada que hacer.'
    exit
}
Write-Host ''
Write-Host 'Se descargara e instalara un mod a la vez. Al final se borraran de la carpeta mods los archivos que no son del paquete.'
Write-Host 'Para cancelar, cierra esta ventana ahora.'
Write-Host 'Pulsa cualquier tecla para continuar...'
try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }

$tmp = Join-Path $env:TEMP ('mods_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$errores = @()
$k = 0
foreach ($b in $bajar) {
    $k++
    $etq = '[{0}/{1}] {2} ({3})' -f $k, $bajar.Count, $b.Nombre, $b.Origen
    $o = Join-Path $tmp $b.Nombre
    $ok = $false
    for ($intento = 1; ($intento -le 3) -and (-not $ok); $intento++) {
        try {
            if ($intento -gt 1) { Write-Host ('   reintentando (' + $intento + ' de 3)...') }
            Bajar $b.Url $o $etq
            if (-not (Es-Jar $o)) { throw 'el archivo descargado no es un jar valido' }
            if ($b.Sha -and ((Sha-Git $o) -ne $b.Sha)) { throw 'descarga incompleta' }
            if ($b.Origen -eq 'Drive' -and $TamDrive.ContainsKey($b.Nombre)) {
                $len = (Get-Item -LiteralPath $o).Length
                if ($len -lt $TamDrive[$b.Nombre][0] -or $len -gt $TamDrive[$b.Nombre][1]) { throw ('tamano inesperado (' + $len + ' bytes): revisa que el ID de Drive de ' + $b.Nombre + ' sea el correcto') }
            }
            Move-Item -LiteralPath $o -Destination (Join-Path $Dest $b.Nombre) -Force
            if ($b.Clave) { $estado[$b.Nombre] = $b.Clave }
            $ok = $true
            Write-Host '   instalado.'
        } catch {
            Write-Host ''
            Write-Host ('   ERROR: ' + $_.Exception.Message)
            if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
        }
    }
    if (-not $ok) { $errores += $b.Nombre }
}
$lineas = @()
foreach ($n in $estado.Keys) { $lineas += ($n + '|' + $estado[$n]) }
if ($lineas.Count -gt 0) { Set-Content -LiteralPath $estadoPath -Value $lineas -Encoding ASCII }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($errores.Count -gt 0) {
    Write-Host ''
    Write-Host ('No se pudieron instalar: ' + ($errores -join ', '))
    Write-Host 'No se borro nada mas. Cierra Minecraft si esta abierto y vuelve a ejecutar:'
    Write-Host 'continua donde se quedo y solo baja lo que falta.'
    exit
}
if ($extras.Count -gt 0) {
    Write-Host ''
    Write-Host ('Borrando ' + $extras.Count + ' archivos que no son del paquete...')
    try {
        foreach ($e in $extras) { Remove-Item -LiteralPath $e.FullName -Force }
    } catch {
        Write-Host 'No se pudo borrar algo. Cierra Minecraft y el launcher y vuelve a ejecutar.'
        Write-Host $_.Exception.Message
        exit
    }
}

$total = @(Get-ChildItem -LiteralPath $Dest -Filter *.jar -File).Count
Write-Host ''
Write-Host '======================================'
Write-Host ('  LISTO. Mods instalados en la carpeta: ' + $total)
Write-Host ('  ' + $Dest)
Write-Host '======================================'
 