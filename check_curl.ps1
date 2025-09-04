# Укажите путь к файлу со списком адресов
param(
    [string]$AddressesFile = "addresses.txt",
    [string]$OutputFile = "results.txt",
    [int]$MaxRetries = 5, # Количество попыток проверки
    [int]$RetryDelay = 2, # Задержка между попытками в секундах
    [int]$Timeout = 10, # Таймаут соединения в секундах
    [int]$MaxThreads = 10, # Максимальное количество параллельных потоков
    [string]$DohUrl = "", # Новый параметр для указания DoH URL (например, "https://cloudflare-dns.com/dns-query")
    [string]$DnsServers = "" # Новый параметр для указания DNS-серверов (например, "8.8.8.8,1.1.1.1")
)

# Функция для получения описания HTTP кода
function Get-HttpCodeDescription {
    param([int]$Code)
    switch ($Code) {
        0 { return "Нет ответа от сервера" }
        200 { return "OK - Страница загружена успешно" }
        201 { return "Created - Ресурс успешно создан" }
        204 { return "No Content - Запрос выполнен, но содержимое отсутствует" }
        301 { return "Moved Permanently - Ресурс перемещен навсегда" }
        302 { return "Found - Ресурс временно перемещен" }
        304 { return "Not Modified - Ресурс не изменялся" }
        400 { return "Bad Request - Некорректный запрос" }
        401 { return "Unauthorized - Требуется авторизация" }
        403 { return "Forbidden - Доступ запрещен" }
        404 { return "Not Found - Страница не найдена" }
        405 { return "Method Not Allowed - Метод запроса не разрешен" }
        408 { return "Request Timeout - Время ожидания истекло" }
        429 { return "Too Many Requests - Слишком много запросов" }
        500 { return "Internal Server Error - Внутренняя ошибка сервера" }
        502 { return "Bad Gateway - Ошибка шлюза" }
        503 { return "Service Unavailable - Сервис временно недоступен" }
        504 { return "Gateway Timeout - Шлюз не отвечает" }
        default {
            if ($Code -ge 200 -and $Code -lt 300) { return "Успешный запрос" }
            elseif ($Code -ge 300 -and $Code -lt 400) { return "Редирект" }
            elseif ($Code -ge 400 -and $Code -lt 500) { return "Ошибка клиента" }
            elseif ($Code -ge 500 -and $Code -lt 600) { return "Ошибка сервера" }
            else { return "Неизвестный код" }
        }
    }
}

# Функция для получения описания ошибки curl
function Get-CurlErrorDescription {
    param([int]$ExitCode)
    switch ($ExitCode) {
        1 { return "Неправильные параметры или использование" }
        2 { return "Не удалось инициализировать" }
        3 { return "Неизвестный протокол" }
        6 { return "Не удалось разрешить имя хоста или DNS-ошибка" }
        7 { return "Не удалось подключиться к серверу" }
        28 { return "Время ожидания соединения истекло" }
        35 { return "Ошибка SSL/TLS соединения" }
        52 { return "Сервер не вернул никаких данных" }
        55 { return "Ошибка отправки сетевых данных" }
        56 { return "Ошибка получения сетевых данных" }
        60 { return "Ошибка проверки SSL-сертификата" }
        67 { return "Неправильное имя пользователя или пароль" } # Добавлено
        77 { return "Ошибка файла сертификата" } # Добавлено
        default { return "Неизвестная ошибка curl (код: $ExitCode)" }
    }
}

# Получаем локальный часовой пояс для отображения
$currentTimeZone = (Get-TimeZone).DisplayName
# Формат даты и времени: День.Месяц.Год Часы:Минуты:Секунды (Часовой пояс)
$customDateTimeFormat = "dd.MM.yyyy HH:mm:ss"
$timestamp = (Get-Date).ToString($customDateTimeFormat) + " ($currentTimeZone)"

# Проверяем, существует ли файл
if (-not (Test-Path $AddressesFile)) {
    Write-Host "Файл $AddressesFile не найден!" -ForegroundColor Red
    Write-Host "Пожалуйста, создайте файл с URL-адресами или укажите правильный путь." -ForegroundColor Yellow
    exit 1
}

# Создаем директорию для результатов, если её нет
$OutputDir = Split-Path $OutputFile -Parent
if ($OutputDir -and -not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Подготовка информации о DNS для отчета
$dnsInfoLine = "DNS: Системный"
if (-not [string]::IsNullOrWhiteSpace($DohUrl)) {
    if ($DohUrl -match "^https://.+") {
        $dnsInfoLine = "DNS: DoH - $DohUrl"
    } else {
        Write-Host "⚠️  Неверный формат DoH URL. Используется системный DNS. Пример: https://cloudflare-dns.com/dns-query" -ForegroundColor Yellow
        $DohUrl = "" # Сбрасываем, чтобы не использовать
    }
} elseif (-not [string]::IsNullOrWhiteSpace($DnsServers)) {
    # Разделяем адреса запятыми и убираем пробелы
    $dnsServerList = $DnsServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($dnsServerList.Count -gt 0) {
        $dnsInfoLine = "DNS: $($dnsServerList -join ', ')"
    }
}

# Очищаем файл результатов
"Результаты проверки сайтов - $timestamp" | Out-File $OutputFile
$dnsInfoLine | Out-File $OutputFile -Append
"=" * 100 | Out-File $OutputFile -Append
"" | Out-File $OutputFile -Append

# Читаем адреса из файла
$rawAddresses = Get-Content $AddressesFile
$addresses = $rawAddresses | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }
if ($addresses.Count -eq 0) {
    Write-Host "⚠️  Файл не содержит действительных URL-адресов!" -ForegroundColor Yellow
    "Файл не содержит действительных URL-адресов" | Out-File $OutputFile -Append
    exit 1
}

# Подготовка аргументов DNS/DoH для curl
$dnsArgs = @()
if (-not [string]::IsNullOrWhiteSpace($DohUrl)) {
    # Проверяем, что URL выглядит как правильный HTTPS URL
    if ($DohUrl -match "^https://.+") {
        $dnsArgs = @('--doh-url', $DohUrl)
        Write-Host "ℹ️  Используется DoH-сервер: $DohUrl" -ForegroundColor Cyan
    }
} elseif (-not [string]::IsNullOrWhiteSpace($DnsServers)) {
    # Разделяем адреса запятыми и убираем пробелы
    $dnsServerList = $DnsServers -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($dnsServerList.Count -gt 0) {
        # curl ожидает --dns-servers ip1,ip2,...
        $dnsArgs = @('--dns-servers', ($dnsServerList -join ','))
        Write-Host "ℹ️  Используются DNS-серверы: $($dnsServerList -join ', ')" -ForegroundColor Cyan
    }
} else {
    Write-Host "ℹ️  Используются системные DNS-настройки." -ForegroundColor Cyan
}

Write-Host "🚀 Начинаю проверку $($addresses.Count) адресов (максимум $MaxRetries попыток, $MaxThreads потоков)..." -ForegroundColor Cyan
Write-Host "=" * 100

# Статистика
$summary = [PSCustomObject]@{
    total = $addresses.Count
    available = 0
    redirect = 0
    unavailable = 0
    errors = 0
    retries = 0
    totalTime = 0
}

# Для хранения детальных результатов
$results = [System.Collections.ArrayList]::new()
$lock = New-Object System.Object

# Функция для проверки одного URL
function Test-Url {
    param(
        [string]$url,
        [int]$MaxRetries,
        [int]$RetryDelay,
        [int]$Timeout,
        [array]$DnsArgs # Новый параметр
    )
    $originalUrl = $url.Trim()
    # Пропускаем пустые строки и комментарии
    if ([string]::IsNullOrEmpty($originalUrl) -or $originalUrl.StartsWith("#")) {
        return $null
    }
    # Если URL не содержит протокол, добавляем https://
    if (-not ($originalUrl -match "^[a-zA-Z]+://")) {
        $testUrl = "https://$originalUrl"
    } else {
        $testUrl = $originalUrl
    }

    # Создаем кликабельную ссылку для консоли
    Write-Host "🔍 Проверяю: " -NoNewline -ForegroundColor Gray
    Write-Host $testUrl -ForegroundColor Blue -NoNewline
    # Попытка извлечь домен для красивого отображения
    try {
        $uri = [System.Uri]$testUrl
        $domain = $uri.Host
        Write-Host " [$domain]" -ForegroundColor DarkGray
    } catch {
        Write-Host ""
    }

    $success = $false
    $retryCount = 0
    $attemptResults = @()
    $finalResult = $null

    # Цикл повторных попыток
    for ($attempt = 1; $attempt -le $MaxRetries -and -not $success; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  ↻ Попытка $attempt/$MaxRetries..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelay
        }
        $startTime = Get-Date
        try {
            # Используем curl для проверки
            # Используем -L для следования редиректам и получения финального ответа
            $curlArgs = @(
                '-I',                    # Только заголовки
                '-L',                    # Следовать редиректам
                '-s',                    # Тихий режим
                '--connect-timeout', $Timeout.ToString(),
                '--max-time', '30'
                # Добавляем аргументы DNS/DoH, если они есть
                if ($DnsArgs.Count -gt 0) { $DnsArgs }
                '-w', "HTTP_CODE:%{http_code}|TOTAL_TIME:%{time_total}|SIZE_DOWNLOAD:%{size_download}|REDIRECT_URL:%{redirect_url}",
                $testUrl
            ) | Where-Object { $_ -ne $null } # Убираем пустые значения, если $DnsArgs пуст

            $curlOutput = & curl.exe @curlArgs 2>$null
            $endTime = Get-Date
            $attemptTime = ($endTime - $startTime).TotalSeconds

            # Сохраняем exit code для анализа
            $curlExitCode = $LASTEXITCODE

            # Обработка вывода curl
            $outputLines = $curlOutput | Where-Object { $_ -ne $null }
            $outputString = $outputLines -join "`n"

            # Извлечение данных
            $httpCode = ""
            $totalTime = ""
            $sizeDownload = ""
            $redirectUrl = "" # Новое поле для финального URL редиректа от curl
            $lastLine = $outputLines[-1]
            if ($lastLine -match "HTTP_CODE:(\d+)\|TOTAL_TIME:([\d\.]+)\|SIZE_DOWNLOAD:(\d+)\|REDIRECT_URL:(.*)") {
                $httpCode = $matches[1]
                $totalTime = $matches[2]
                $sizeDownload = $matches[3]
                $redirectUrl = $matches[4].Trim() # Сохраняем финальный URL редиректа
            }
            elseif ($outputString -match "HTTP_CODE:(\d+)") {
                $httpCode = $matches[1]
            }

            # Поиск HTTP кода в заголовках
            $headerLines = $outputLines | Where-Object { $_ -match "^HTTP/" }
            $lastHeaderCode = ""
            if ($headerLines) {
                $lastHeader = $headerLines[-1]
                if ($lastHeader -match "HTTP/\d+\.\d+\s+(\d+)") {
                    $lastHeaderCode = $matches[1]
                }
            }
            if ([string]::IsNullOrEmpty($httpCode) -and $lastHeaderCode) {
                $httpCode = $lastHeaderCode
            }

            # Если все еще пусто, проверяем exit code
            if ([string]::IsNullOrEmpty($httpCode)) {
                if ($curlExitCode -ne 0) {
                    $httpCode = "000"
                } else {
                    # Если exit code 0, но код не получен, ставим 0
                    $httpCode = "0"
                }
            }

            # Проверка редиректов
            # Мы используем redirect_url из curl, так как -L уже обработал всю цепочку
            $isRedirect = $false
            $redirectLocation = ""
            if (-not [string]::IsNullOrWhiteSpace($redirectUrl)) {
                $isRedirect = $true
                $redirectLocation = $redirectUrl
            } else {
                # Если curl не предоставил redirect_url, проверяем Location в последнем ответе
                $locationHeaders = $outputLines | Where-Object { $_ -match "^[Ll]ocation:" }
                if ($locationHeaders) {
                    $isRedirect = $true
                    $redirectLocation = ($locationHeaders[-1] -replace "^[Ll]ocation:\s*", "").Trim()
                    # Пытаемся построить полный URL, если Location относительный
                    if ($redirectLocation -and -not ($redirectLocation -match "^[a-zA-Z]+://")) {
                        try {
                            $originalUri = [System.Uri]$testUrl
                            if ($redirectLocation.StartsWith("/")) {
                                # Абсолютный путь
                                $redirectLocation = "$($originalUri.Scheme)://$($originalUri.Host)$redirectLocation"
                            } else {
                                # Относительный путь (упрощенная логика)
                                $basePath = $originalUri.AbsolutePath
                                if (-not $basePath.EndsWith("/")) {
                                    $basePath = [System.IO.Path]::GetDirectoryName($basePath).Replace("\", "/")
                                    if (-not $basePath.EndsWith("/")) { $basePath += "/" }
                                }
                                $redirectLocation = "$($originalUri.Scheme)://$($originalUri.Host)$basePath$redirectLocation"
                            }
                        } catch {
                            # Если не удалось построить полный URL, оставляем как есть
                        }
                    }
                }
            }

            [int]$code = if ([string]::IsNullOrEmpty($httpCode)) { 0 } else { [int]$httpCode }
            $attemptResult = @{
                attempt = $attempt
                code = $code
                isRedirect = $isRedirect
                redirectLocation = $redirectLocation
                totalTime = $totalTime
                sizeDownload = $sizeDownload
                executionTime = $attemptTime
                curlExitCode = $curlExitCode
            }
            $attemptResults += $attemptResult

            # Проверяем успешность
            if ($code -ge 200 -and $code -lt 400) {
                $success = $true
                $retryCount = $attempt - 1
                $finalResult = $attemptResult
                if ($isRedirect) {
                    Write-Host "  ⚠️  [РЕДИРЕКТ] Код: $httpCode" -ForegroundColor Yellow
                    Write-Host "     $(Get-HttpCodeDescription -Code $code)" -ForegroundColor DarkYellow
                    if ($redirectLocation) {
                        Write-Host "     Перенаправление на: " -NoNewline -ForegroundColor Yellow
                        Write-Host $redirectLocation -ForegroundColor Blue
                    }
                    if ($totalTime) {
                        Write-Host "     Время: $($totalTime)s" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "  ✅ [ДОСТУПЕН] Код: $httpCode" -ForegroundColor Green
                    Write-Host "     $(Get-HttpCodeDescription -Code $code)" -ForegroundColor DarkGreen
                    if ($totalTime) {
                        Write-Host "     Время: $($totalTime)s" -ForegroundColor Gray
                    }
                    if ($sizeDownload -and [int]$sizeDownload -gt 0) {
                        Write-Host "     Размер: $sizeDownload байт" -ForegroundColor Gray
                    }
                }
            }
            elseif ($attempt -eq $MaxRetries) {
                # Последняя попытка не удалась
                if ($code -eq 0 -or $code -eq "000") {
                    Write-Host "  ⚠️  [НЕТ ОТВЕТА] Код: $httpCode" -ForegroundColor Magenta
                    if ($curlExitCode -ne 0) {
                        Write-Host "     Ошибка curl: $curlExitCode - $(Get-CurlErrorDescription -ExitCode $curlExitCode)" -ForegroundColor DarkMagenta
                    } else {
                        Write-Host "     Нет ответа от сервера" -ForegroundColor DarkMagenta
                    }
                } else {
                    Write-Host "  ❌ [НЕДОСТУПЕН] Код: $httpCode" -ForegroundColor Red
                    Write-Host "     $(Get-HttpCodeDescription -Code $code)" -ForegroundColor DarkRed
                }
                if ($totalTime) {
                    Write-Host "     Время: $($totalTime)s" -ForegroundColor Gray
                }
                $finalResult = $attemptResult
            }
        }
        catch {
            $attemptTime = (Get-Date - $startTime).TotalSeconds
            $attemptResult = @{
                attempt = $attempt
                code = 0
                error = $_.Exception.Message
                executionTime = $attemptTime
                curlExitCode = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { -1 }
            }
            $attemptResults += $attemptResult
            if ($attempt -eq $MaxRetries) {
                Write-Host "  ⚠️  [ОШИБКА] $($_.Exception.Message)" -ForegroundColor Magenta
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "     Описание ошибки: $(Get-CurlErrorDescription -ExitCode $LASTEXITCODE)" -ForegroundColor DarkMagenta
                }
                $finalResult = $attemptResult
            }
        }
    }

    # Определяем категорию результата для сортировки
    $category = if ($success) {
        if ($finalResult.isRedirect) {
            if ($retryCount -gt 0) { "redirect_retry" } else { "redirect_first" }
        } else {
            if ($retryCount -gt 0) { "available_retry" } else { "available_first" }
        }
    } else {
        if ($finalResult.code -eq 0 -or $finalResult.code -eq "000" -or $finalResult.curlExitCode -ne 0) { "error" } else { "unavailable" }
    }

    # Извлекаем домен
    $domain = try { ([System.Uri]$testUrl).Host } catch { $originalUrl }
    Write-Host ""
    return [PSCustomObject]@{
        Url = $originalUrl
        TestUrl = $testUrl
        FinalResult = $finalResult
        AttemptResults = $attemptResults
        RetryCount = $retryCount
        Success = $success
        Category = $category
        Domain = $domain
        StatusCode = $finalResult.code
        ResponseTime = if ($finalResult.totalTime) { [double]$finalResult.totalTime } else { 0 }
    }
}

# Параллельная обработка URL-адресов
$runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
$runspacePool.Open()
$jobs = @()
$addresses | ForEach-Object {
    $scriptBlock = {
        param($url, $MaxRetries, $RetryDelay, $Timeout, $DnsArgs)

        # Передаем все необходимые функции в скриптблок
        function Get-HttpCodeDescription {
            param([int]$Code)
            switch ($Code) {
                0 { return "Нет ответа от сервера" }
                200 { return "OK - Страница загружена успешно" }
                201 { return "Created - Ресурс успешно создан" }
                204 { return "No Content - Запрос выполнен, но содержимое отсутствует" }
                301 { return "Moved Permanently - Ресурс перемещен навсегда" }
                302 { return "Found - Ресурс временно перемещен" }
                304 { return "Not Modified - Ресурс не изменялся" }
                400 { return "Bad Request - Некорректный запрос" }
                401 { return "Unauthorized - Требуется авторизация" }
                403 { return "Forbidden - Доступ запрещен" }
                404 { return "Not Found - Страница не найдена" }
                405 { return "Method Not Allowed - Метод запроса не разрешен" }
                408 { return "Request Timeout - Время ожидания истекло" }
                429 { return "Too Many Requests - Слишком много запросов" }
                500 { return "Internal Server Error - Внутренняя ошибка сервера" }
                502 { return "Bad Gateway - Ошибка шлюза" }
                503 { return "Service Unavailable - Сервис временно недоступен" }
                504 { return "Gateway Timeout - Шлюз не отвечает" }
                default {
                    if ($Code -ge 200 -and $Code -lt 300) { return "Успешный запрос" }
                    elseif ($Code -ge 300 -and $Code -lt 400) { return "Редирект" }
                    elseif ($Code -ge 400 -and $Code -lt 500) { return "Ошибка клиента" }
                    elseif ($Code -ge 500 -and $Code -lt 600) { return "Ошибка сервера" }
                    else { return "Неизвестный код" }
                }
            }
        }
        function Get-CurlErrorDescription {
            param([int]$ExitCode)
            switch ($ExitCode) {
                1 { return "Неправильные параметры или использование" }
                2 { return "Не удалось инициализировать" }
                3 { return "Неизвестный протокол" }
                6 { return "Не удалось разрешить имя хоста или DNS-ошибка" }
                7 { return "Не удалось подключиться к серверу" }
                28 { return "Время ожидания соединения истекло" }
                35 { return "Ошибка SSL/TLS соединения" }
                52 { return "Сервер не вернул никаких данных" }
                55 { return "Ошибка отправки сетевых данных" }
                56 { return "Ошибка получения сетевых данных" }
                60 { return "Ошибка проверки SSL-сертификата" }
                67 { return "Неправильное имя пользователя или пароль" }
                77 { return "Ошибка файла сертификата" }
                default { return "Неизвестная ошибка curl (код: $ExitCode)" }
            }
        }

        # Функция для проверки одного URL
        function Test-Url {
            param(
                [string]$url,
                [int]$MaxRetries,
                [int]$RetryDelay,
                [int]$Timeout,
                [array]$DnsArgs # Новый параметр
            )
            $originalUrl = $url.Trim()
            # Пропускаем пустые строки и комментарии
            if ([string]::IsNullOrEmpty($originalUrl) -or $originalUrl.StartsWith("#")) {
                return $null
            }
            # Если URL не содержит протокол, добавляем https://
            if (-not ($originalUrl -match "^[a-zA-Z]+://")) {
                $testUrl = "https://$originalUrl"
            } else {
                $testUrl = $originalUrl
            }

            $success = $false
            $retryCount = 0
            $attemptResults = @()
            $finalResult = $null

            # Цикл повторных попыток
            for ($attempt = 1; $attempt -le $MaxRetries -and -not $success; $attempt++) {
                if ($attempt -gt 1) {
                    Start-Sleep -Seconds $RetryDelay
                }
                $startTime = Get-Date
                try {
                    # Используем curl для проверки
                     $curlArgs = @(
                        '-I',                    # Только заголовки
                        '-L',                    # Следовать редиректам
                        '-s',                    # Тихий режим
                        '--connect-timeout', $Timeout.ToString(),
                        '--max-time', '30'
                        # Добавляем аргументы DNS/DoH, если они есть
                        if ($DnsArgs.Count -gt 0) { $DnsArgs }
                        '-w', "HTTP_CODE:%{http_code}|TOTAL_TIME:%{time_total}|SIZE_DOWNLOAD:%{size_download}|REDIRECT_URL:%{redirect_url}",
                        $testUrl
                    ) | Where-Object { $_ -ne $null } # Убираем пустые значения, если $DnsArgs пуст

                    $curlOutput = & curl.exe @curlArgs 2>$null
                    $endTime = Get-Date
                    $attemptTime = ($endTime - $startTime).TotalSeconds

                    # Сохраняем exit code для анализа
                    $curlExitCode = $LASTEXITCODE

                    # Обработка вывода curl
                    $outputLines = $curlOutput | Where-Object { $_ -ne $null }
                    $outputString = $outputLines -join "`n"

                    # Извлечение данных
                    $httpCode = ""
                    $totalTime = ""
                    $sizeDownload = ""
                    $redirectUrl = ""
                    $lastLine = $outputLines[-1]
                    if ($lastLine -match "HTTP_CODE:(\d+)\|TOTAL_TIME:([\d\.]+)\|SIZE_DOWNLOAD:(\d+)\|REDIRECT_URL:(.*)") {
                        $httpCode = $matches[1]
                        $totalTime = $matches[2]
                        $sizeDownload = $matches[3]
                        $redirectUrl = $matches[4].Trim()
                    }
                    elseif ($outputString -match "HTTP_CODE:(\d+)") {
                        $httpCode = $matches[1]
                    }

                    # Поиск HTTP кода в заголовках
                    $headerLines = $outputLines | Where-Object { $_ -match "^HTTP/" }
                    $lastHeaderCode = ""
                    if ($headerLines) {
                        $lastHeader = $headerLines[-1]
                        if ($lastHeader -match "HTTP/\d+\.\d+\s+(\d+)") {
                            $lastHeaderCode = $matches[1]
                        }
                    }
                    if ([string]::IsNullOrEmpty($httpCode) -and $lastHeaderCode) {
                        $httpCode = $lastHeaderCode
                    }

                    # Если все еще пусто, проверяем exit code
                    if ([string]::IsNullOrEmpty($httpCode)) {
                        if ($curlExitCode -ne 0) {
                            $httpCode = "000"
                        } else {
                            $httpCode = "0"
                        }
                    }

                    # Проверка редиректов
                    $isRedirect = $false
                    $redirectLocation = ""
                    if (-not [string]::IsNullOrWhiteSpace($redirectUrl)) {
                        $isRedirect = $true
                        $redirectLocation = $redirectUrl
                    } else {
                        $locationHeaders = $outputLines | Where-Object { $_ -match "^[Ll]ocation:" }
                        if ($locationHeaders) {
                            $isRedirect = $true
                            $redirectLocation = ($locationHeaders[-1] -replace "^[Ll]ocation:\s*", "").Trim()
                            if ($redirectLocation -and -not ($redirectLocation -match "^[a-zA-Z]+://")) {
                                try {
                                    $originalUri = [System.Uri]$testUrl
                                    if ($redirectLocation.StartsWith("/")) {
                                        $redirectLocation = "$($originalUri.Scheme)://$($originalUri.Host)$redirectLocation"
                                    } else {
                                        $basePath = $originalUri.AbsolutePath
                                        if (-not $basePath.EndsWith("/")) {
                                            $basePath = [System.IO.Path]::GetDirectoryName($basePath).Replace("\", "/")
                                            if (-not $basePath.EndsWith("/")) { $basePath += "/" }
                                        }
                                        $redirectLocation = "$($originalUri.Scheme)://$($originalUri.Host)$basePath$redirectLocation"
                                    }
                                } catch {
                                    # Если не удалось построить полный URL, оставляем как есть
                                }
                            }
                        }
                    }

                    [int]$code = if ([string]::IsNullOrEmpty($httpCode)) { 0 } else { [int]$httpCode }
                    $attemptResult = @{
                        attempt = $attempt
                        code = $code
                        isRedirect = $isRedirect
                        redirectLocation = $redirectLocation
                        totalTime = $totalTime
                        sizeDownload = $sizeDownload
                        executionTime = $attemptTime
                        curlExitCode = $curlExitCode
                    }
                    $attemptResults += $attemptResult

                    # Проверяем успешность
                    if ($code -ge 200 -and $code -lt 400) {
                        $success = $true
                        $retryCount = $attempt - 1
                        $finalResult = $attemptResult
                    }
                    elseif ($attempt -eq $MaxRetries) {
                        $finalResult = $attemptResult
                    }
                }
                catch {
                    $attemptTime = (Get-Date - $startTime).TotalSeconds
                    $attemptResult = @{
                        attempt = $attempt
                        code = 0
                        error = $_.Exception.Message
                        executionTime = $attemptTime
                        curlExitCode = if (Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue) { $LASTEXITCODE } else { -1 }
                    }
                    $attemptResults += $attemptResult
                    if ($attempt -eq $MaxRetries) {
                        $finalResult = $attemptResult
                    }
                }
            }

            # Определяем категорию результата для сортировки
            $category = if ($success) {
                if ($finalResult.isRedirect) {
                    if ($retryCount -gt 0) { "redirect_retry" } else { "redirect_first" }
                } else {
                    if ($retryCount -gt 0) { "available_retry" } else { "available_first" }
                }
            } else {
                if ($finalResult.code -eq 0 -or $finalResult.code -eq "000" -or $finalResult.curlExitCode -ne 0) { "error" } else { "unavailable" }
            }

            # Извлекаем домен
            $domain = try { ([System.Uri]$testUrl).Host } catch { $originalUrl }
            return [PSCustomObject]@{
                Url = $originalUrl
                TestUrl = $testUrl
                FinalResult = $finalResult
                AttemptResults = $attemptResults
                RetryCount = $retryCount
                Success = $success
                Category = $category
                Domain = $domain
                StatusCode = $finalResult.code
                ResponseTime = if ($finalResult.totalTime) { [double]$finalResult.totalTime } else { 0 }
            }
        }
        return Test-Url -url $url -MaxRetries $MaxRetries -RetryDelay $RetryDelay -Timeout $Timeout -DnsArgs $DnsArgs
    }
    $powershell = [powershell]::Create()
    $powershell.RunspacePool = $runspacePool
    [void]$powershell.AddScript($scriptBlock).AddArgument($_).AddArgument($MaxRetries).AddArgument($RetryDelay).AddArgument($Timeout).AddArgument($dnsArgs)
    $jobs += [PSCustomObject]@{
        PowerShell = $powershell
        Handle = $powershell.BeginInvoke()
    }
}

# Собираем результаты
Write-Host "⏳ Ожидание завершения всех проверок..." -ForegroundColor Cyan
$completedJobs = 0
$totalJobs = $jobs.Count
foreach ($job in $jobs) {
    $result = $job.PowerShell.EndInvoke($job.Handle)
    if ($result -ne $null) {
        [void]$results.Add($result)
        # Обновляем статистику потокобезопасно
        [System.Threading.Monitor]::Enter($lock)
        try {
            switch ($result.Category) {
                "available_first" { $summary.available++ }
                "available_retry" {
                    $summary.available++
                    $summary.retries++
                }
                "redirect_first" { $summary.redirect++ }
                "redirect_retry" {
                    $summary.redirect++
                    $summary.retries++
                }
                "unavailable" { $summary.unavailable++ }
                "error" { $summary.errors++ }
            }
            if ($result.ResponseTime -gt 0) {
                $summary.totalTime += $result.ResponseTime
            }
        }
        finally {
            [System.Threading.Monitor]::Exit($lock)
        }
    }
    $completedJobs++
    Write-Progress -Activity "Проверка сайтов" -Status "Завершено: $completedJobs из $totalJobs" -PercentComplete (($completedJobs / $totalJobs) * 100)
    $job.PowerShell.Dispose()
}
$runspacePool.Close()
$runspacePool.Dispose()
Write-Progress -Activity "Проверка сайтов" -Completed

# Выводим сводку
Write-Host "=" * 100 -ForegroundColor Cyan
Write-Host "📊 СВОДКА ПРОВЕРКИ:" -ForegroundColor Cyan
Write-Host "   Всего проверено: $($summary.total)" -ForegroundColor Cyan
Write-Host "   ✅ Доступно: $($summary.available)" -ForegroundColor Green
Write-Host "   ⚠️  Редиректы: $($summary.redirect)" -ForegroundColor Yellow
Write-Host "   ❌ Недоступно: $($summary.unavailable)" -ForegroundColor Red
Write-Host "   ⚠️  Ошибки: $($summary.errors)" -ForegroundColor Magenta
Write-Host "   🔄 Успешные повторные попытки: $($summary.retries)" -ForegroundColor Blue
# Среднее время ответа
if (($summary.available + $summary.redirect) -gt 0 -and $summary.totalTime -gt 0) {
    $avgTime = $summary.totalTime / ($summary.available + $summary.redirect)
    Write-Host "   ⏱️  Среднее время ответа: $(('{0:F3}' -f $avgTime))s" -ForegroundColor Cyan
}
Write-Host "=" * 100 -ForegroundColor Cyan

# Сортировка результатов по категориям
Write-Host "📋 СОРТИРОВКА РЕЗУЛЬТАТОВ:" -ForegroundColor Cyan
Write-Host ""

# 1. Сайты, доступные с первой попытки
$firstTryAvailable = $results | Where-Object { $_.Category -eq "available_first" } | Sort-Object { $_.Domain }
if ($firstTryAvailable.Count -gt 0) {
    Write-Host "✅ ДОСТУПНЫ С ПЕРВОЙ ПОПЫТКИ ($($firstTryAvailable.Count)):" -ForegroundColor Green
    foreach ($result in $firstTryAvailable) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        Write-Host "     Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode)" -ForegroundColor Gray
        if ($result.ResponseTime -gt 0) {
            Write-Host "     Время: $(('{0:F3}' -f $result.ResponseTime))s" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# 2. Сайты, доступные после повторных попыток
$retryAvailable = $results | Where-Object { $_.Category -eq "available_retry" } | Sort-Object { $_.Domain }
if ($retryAvailable.Count -gt 0) {
    Write-Host "🔄 ДОСТУПНЫ ПОСЛЕ ПОВТОРНЫХ ПОПЫТОК ($($retryAvailable.Count)):" -ForegroundColor Blue
    foreach ($result in $retryAvailable) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        Write-Host "     Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode)" -ForegroundColor Gray
        Write-Host "     Попыток: $($result.RetryCount + 1)" -ForegroundColor Gray
        if ($result.ResponseTime -gt 0) {
            Write-Host "     Время: $(('{0:F3}' -f $result.ResponseTime))s" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# 3. Редиректы с первой попытки
$firstTryRedirect = $results | Where-Object { $_.Category -eq "redirect_first" } | Sort-Object { $_.Domain }
if ($firstTryRedirect.Count -gt 0) {
    Write-Host "⚠️  РЕДИРЕКТЫ С ПЕРВОЙ ПОПЫТКИ ($($firstTryRedirect.Count)):" -ForegroundColor Yellow
    foreach ($result in $firstTryRedirect) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        Write-Host "     Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode)" -ForegroundColor Yellow
        if ($result.FinalResult.redirectLocation) {
            Write-Host "     Перенаправление на: " -NoNewline -ForegroundColor Yellow
            Write-Host $result.FinalResult.redirectLocation -ForegroundColor Blue
        }
    }
    Write-Host ""
}

# 4. Редиректы после повторных попыток
$retryRedirect = $results | Where-Object { $_.Category -eq "redirect_retry" } | Sort-Object { $_.Domain }
if ($retryRedirect.Count -gt 0) {
    Write-Host "🔄⚠️  РЕДИРЕКТЫ ПОСЛЕ ПОВТОРНЫХ ПОПЫТОК ($($retryRedirect.Count)):" -ForegroundColor DarkYellow
    foreach ($result in $retryRedirect) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        Write-Host "     Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode)" -ForegroundColor Yellow
        if ($result.FinalResult.redirectLocation) {
            Write-Host "     Перенаправление на: " -NoNewline -ForegroundColor Yellow
            Write-Host $result.FinalResult.redirectLocation -ForegroundColor Blue
        }
        Write-Host "     Попыток: $($result.RetryCount + 1)" -ForegroundColor Yellow
    }
    Write-Host ""
}

# 5. Недоступные сайты
$unavailableSites = $results | Where-Object { $_.Category -eq "unavailable" } | Sort-Object { $_.Domain }
if ($unavailableSites.Count -gt 0) {
    Write-Host "❌ НЕДОСТУПНЫ ($($unavailableSites.Count)):" -ForegroundColor Red
    foreach ($result in $unavailableSites) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        Write-Host "     Код ошибки: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode)" -ForegroundColor Red
    }
    Write-Host ""
}

# 6. Сайты с ошибками
$errorSites = $results | Where-Object { $_.Category -eq "error" } | Sort-Object { $_.Domain }
if ($errorSites.Count -gt 0) {
    Write-Host "⚠️  ОШИБКИ ($($errorSites.Count)):" -ForegroundColor Magenta
    foreach ($result in $errorSites) {
        Write-Host "   " -NoNewline
        Write-Host $result.TestUrl -ForegroundColor Blue
        if ($result.FinalResult.curlExitCode -ne 0 -and $result.FinalResult.curlExitCode -ne $null) {
            Write-Host "     Ошибка curl: $($result.FinalResult.curlExitCode) - $(Get-CurlErrorDescription -ExitCode $result.FinalResult.curlExitCode)" -ForegroundColor Magenta
        } elseif ($result.FinalResult.error) {
            Write-Host "     $($result.FinalResult.error)" -ForegroundColor Magenta
        } else {
            Write-Host "     Нет ответа от сервера" -ForegroundColor Magenta
        }
    }
    Write-Host ""
}

# Записываем детальные результаты в файл TXT
"" | Out-File $outputFile -Append
"ДЕТАЛЬНЫЕ РЕЗУЛЬТАТЫ:" | Out-File $outputFile -Append
"=" * 100 | Out-File $outputFile -Append
foreach ($result in $results) {
    $status = switch ($result.Category) {
        "available_first" { "✅ ДОСТУПЕН (с первой попытки)" }
        "available_retry" { "🔄 ДОСТУПЕН (после повторных попыток)" }
        "redirect_first" { "⚠️  РЕДИРЕКТ (с первой попытки)" }
        "redirect_retry" { "🔄⚠️  РЕДИРЕКТ (после повторных попыток)" }
        "unavailable" { "❌ НЕДОСТУПЕН" }
        "error" { "⚠️  ОШИБКА" }
        default { "❓ НЕИЗВЕСТНО" }
    }
    $resultLine = "[$($result.Url)] - $status"
    if ($result.StatusCode -ne 0 -and $result.StatusCode -ne "000") {
        $resultLine += " (Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode))"
    } elseif ($result.StatusCode -eq 0 -or $result.StatusCode -eq "000") {
        if ($result.FinalResult.curlExitCode -ne 0 -and $result.FinalResult.curlExitCode -ne $null) {
            $resultLine += " (Нет ответа - ошибка curl: $($result.FinalResult.curlExitCode))"
        } else {
            $resultLine += " (Нет ответа от сервера)"
        }
    }
    if ($result.FinalResult.redirectLocation) {
        $resultLine += " -> $($result.FinalResult.redirectLocation)"
    }
    if ($result.RetryCount -gt 0) {
        $resultLine += " (попыток: $($result.RetryCount + 1))"
    }
    if ($result.ResponseTime -gt 0) {
        $resultLine += " (время: $(('{0:F3}' -f $result.ResponseTime))s)"
    }
    $resultLine | Out-File $outputFile -Append
    # Детали по попыткам
    if ($result.AttemptResults.Count -gt 1) {
        "    Попытки: " + ($result.AttemptResults | ForEach-Object {
            if ($_.code -ne 0 -and $_.code -ne "000") { "Попытка $($_.attempt): Код $($_.code)" }
            else { "Попытка $($_.attempt): Ошибка" }
        }) -join ", " | Out-File $outputFile -Append
    }
}

# Сортированные результаты в файл TXT
"" | Out-File $outputFile -Append
"=" * 100 | Out-File $outputFile -Append
"СОРТИРОВАННЫЕ РЕЗУЛЬТАТЫ:" | Out-File $outputFile -Append
"=" * 100 | Out-File $outputFile -Append

# Функция для записи категории в файл TXT
function Write-CategoryToFile {
    param($Results, $Title, $OutputFile)
    if ($Results.Count -gt 0) {
        "" | Out-File $outputFile -Append
        "$Title ($($Results.Count)):" | Out-File $outputFile -Append
        "=" * 50 | Out-File $outputFile -Append
        foreach ($result in $Results) {
            $line = $result.TestUrl
            if ($result.StatusCode -ne 0 -and $result.StatusCode -ne "000") {
                $line += " (Код: $($result.StatusCode) - $(Get-HttpCodeDescription -Code $result.StatusCode))"
            } elseif ($result.StatusCode -eq 0 -or $result.StatusCode -eq "000") {
                if ($result.FinalResult.curlExitCode -ne 0 -and $result.FinalResult.curlExitCode -ne $null) {
                    $line += " (Нет ответа - ошибка curl: $($result.FinalResult.curlExitCode))"
                } else {
                    $line += " (Нет ответа от сервера)"
                }
            }
            if ($result.FinalResult.redirectLocation) {
                $line += " -> $($result.FinalResult.redirectLocation)"
            }
            if ($result.RetryCount -gt 0) {
                $line += " (попыток: $($result.RetryCount + 1))"
            }
            if ($result.ResponseTime -gt 0) {
                $line += " (время: $(('{0:F3}' -f $result.ResponseTime))s)"
            }
            $line | Out-File $outputFile -Append
        }
    }
}

# Записываем каждую категорию в TXT
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "available_first" } | Sort-Object { $_.Domain }) -Title "✅ ДОСТУПНЫ С ПЕРВОЙ ПОПЫТКИ" -OutputFile $outputFile
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "available_retry" } | Sort-Object { $_.Domain }) -Title "🔄 ДОСТУПНЫ ПОСЛЕ ПОВТОРНЫХ ПОПЫТОК" -OutputFile $outputFile
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "redirect_first" } | Sort-Object { $_.Domain }) -Title "⚠️  РЕДИРЕКТЫ С ПЕРВОЙ ПОПЫТКИ" -OutputFile $outputFile
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "redirect_retry" } | Sort-Object { $_.Domain }) -Title "🔄⚠️  РЕДИРЕКТЫ ПОСЛЕ ПОВТОРНЫХ ПОПЫТОК" -OutputFile $outputFile
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "unavailable" } | Sort-Object { $_.Domain }) -Title "❌ НЕДОСТУПНЫ" -OutputFile $outputFile
Write-CategoryToFile -Results ($results | Where-Object { $_.Category -eq "error" } | Sort-Object { $_.Domain }) -Title "⚠️  ОШИБКИ" -OutputFile $outputFile

# Записываем сводку в файл TXT
"" | Out-File $outputFile -Append
"=" * 100 | Out-File $outputFile -Append
"СВОДКА:" | Out-File $outputFile -Append
"Всего проверено: $($summary.total)" | Out-File $outputFile -Append
"✅ Доступно: $($summary.available)" | Out-File $outputFile -Append
"⚠️  Редиректы: $($summary.redirect)" | Out-File $outputFile -Append
"❌ Недоступно: $($summary.unavailable)" | Out-File $outputFile -Append
"⚠️  Ошибки: $($summary.errors)" | Out-File $outputFile -Append
"🔄 Успешные повторные попытки: $($summary.retries)" | Out-File $outputFile -Append
if (($summary.available + $summary.redirect) -gt 0 -and $summary.totalTime -gt 0) {
    $avgTime = $summary.totalTime / ($summary.available + $summary.redirect)
    "⏱️  Среднее время ответа: $(('{0:F3}' -f $avgTime))s" | Out-File $outputFile -Append
}
Write-Host "Подробные результаты сохранены в файл: $OutputFile" -ForegroundColor Blue

# Экспорт в CSV для дальнейшего анализа
$csvFile = [System.IO.Path]::ChangeExtension($OutputFile, ".csv")
$results | ForEach-Object {
    [PSCustomObject]@{
        URL = $_.Url
        TestURL = $_.TestUrl
        Status = switch ($_.Category) {
            "available_first" { "✅ Доступен (1 попытка)" }
            "available_retry" { "🔄 Доступен (повторные попытки)" }
            "redirect_first" { "⚠️  Редирект (1 попытка)" }
            "redirect_retry" { "🔄⚠️  Редирект (повторные попытки)" }
            "unavailable" { "❌ Недоступен" }
            "error" { "⚠️  Ошибка" }
            default { "❓ Неизвестно" }
        }
        FinalCode = $_.StatusCode
        CodeDescription = if ($_.StatusCode -ne 0) { Get-HttpCodeDescription -Code $_.StatusCode } else { "" }
        RedirectLocation = $_.FinalResult.redirectLocation
        RetryCount = $_.RetryCount
        TotalTime = $_.ResponseTime
        Domain = $_.Domain
        CurlExitCode = $_.FinalResult.curlExitCode
    }
} | Export-Csv -Path $csvFile -Encoding UTF8 -NoTypeInformation
Write-Host "CSV-отчет сохранен в файл: $csvFile" -ForegroundColor Blue

# Экспорт в Markdown для дальнейшего анализа и отчетности
$mdFile = [System.IO.Path]::ChangeExtension($OutputFile, ".md")
"# Отчет о проверке сайтов" | Out-File $mdFile -Encoding UTF8
"" | Out-File $mdFile -Append
"**Дата проверки:** $timestamp  " | Out-File $mdFile -Append
"**$dnsInfoLine**  " | Out-File $mdFile -Append
"" | Out-File $mdFile -Append
"## 📊 Сводка проверки" | Out-File $mdFile -Append
"" | Out-File $mdFile -Append
"| Показатель | Значение |" | Out-File $mdFile -Append
"| :--- | :--- |" | Out-File $mdFile -Append
"| Всего проверено | $($summary.total) |" | Out-File $mdFile -Append
"| ✅ Доступно | $($summary.available) |" | Out-File $mdFile -Append
"| ⚠️  Редиректы | $($summary.redirect) |" | Out-File $mdFile -Append
"| ❌ Недоступно | $($summary.unavailable) |" | Out-File $mdFile -Append
"| ⚠️  Ошибки | $($summary.errors) |" | Out-File $mdFile -Append
"| 🔄 Успешные повторные попытки | $($summary.retries) |" | Out-File $mdFile -Append
if (($summary.available + $summary.redirect) -gt 0 -and $summary.totalTime -gt 0) {
    $avgTime = $summary.totalTime / ($summary.available + $summary.redirect)
    "| ⏱️  Среднее время ответа | $(('{0:F3}' -f $avgTime))s |" | Out-File $mdFile -Append
}
"" | Out-File $mdFile -Append

# Функция для записи категории в файл Markdown
function Write-MdCategory {
    param($Results, $Title, $MdFile)
    if ($Results.Count -gt 0) {
        "## $Title ($($Results.Count))" | Out-File $mdFile -Append
        "" | Out-File $mdFile -Append
        "| URL | Статус | Код | Описание | Дополнительно |" | Out-File $mdFile -Append
        "| :--- | :--- | :--- | :--- | :--- |" | Out-File $mdFile -Append
        foreach ($result in $Results) {
            $url = "[$($result.TestUrl)]($($result.TestUrl))"
            $status = switch ($result.Category) {
                "available_first" { "✅ Доступен (1 попытка)" }
                "available_retry" { "🔄 Доступен (повторные попытки)" }
                "redirect_first" { "⚠️  Редирект (1 попытка)" }
                "redirect_retry" { "🔄⚠️  Редирект (повторные попытки)" }
                "unavailable" { "❌ Недоступен" }
                "error" { "⚠️  Ошибка" }
                default { "❓ Неизвестно" }
            }
            $code = if ($result.StatusCode -ne 0 -and $result.StatusCode -ne "000") { $result.StatusCode } else { "N/A" }
            $description = if ($result.StatusCode -ne 0 -and $result.StatusCode -ne "000") { Get-HttpCodeDescription -Code $result.StatusCode } else { "" }
            if ($result.StatusCode -eq 0 -or $result.StatusCode -eq "000") {
                if ($result.FinalResult.curlExitCode -ne 0 -and $result.FinalResult.curlExitCode -ne $null) {
                    $description = "Ошибка curl: $($result.FinalResult.curlExitCode) - $(Get-CurlErrorDescription -ExitCode $result.FinalResult.curlExitCode)"
                } elseif ($result.FinalResult.error) {
                    $description = $result.FinalResult.error
                } else {
                    $description = "Нет ответа от сервера"
                }
            }
            
            $additional = @()
            if ($result.FinalResult.redirectLocation) {
                $additional += "Перенаправление на: [$($result.FinalResult.redirectLocation)]($($result.FinalResult.redirectLocation))"
            }
            if ($result.RetryCount -gt 0) {
                $additional += "Попыток: $($result.RetryCount + 1)"
            }
            if ($result.ResponseTime -gt 0) {
                $additional += "Время: $(('{0:F3}' -f $result.ResponseTime))s"
            }
            $additionalStr = $additional -join "; "
            
            "| $url | $status | $code | $description | $additionalStr |" | Out-File $mdFile -Append
        }
        "" | Out-File $mdFile -Append
    }
}

# Записываем каждую категорию в Markdown
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "available_first" } | Sort-Object { $_.Domain }) -Title "✅ Доступны с первой попытки" -MdFile $mdFile
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "available_retry" } | Sort-Object { $_.Domain }) -Title "🔄 Доступны после повторных попыток" -MdFile $mdFile
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "redirect_first" } | Sort-Object { $_.Domain }) -Title "⚠️  Редиректы с первой попытки" -MdFile $mdFile
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "redirect_retry" } | Sort-Object { $_.Domain }) -Title "🔄⚠️  Редиректы после повторных попыток" -MdFile $mdFile
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "unavailable" } | Sort-Object { $_.Domain }) -Title "❌ Недоступны" -MdFile $mdFile
Write-MdCategory -Results ($results | Where-Object { $_.Category -eq "error" } | Sort-Object { $_.Domain }) -Title "⚠️  Ошибки" -MdFile $mdFile

Write-Host "Markdown-отчет сохранен в файл: $mdFile" -ForegroundColor Blue
