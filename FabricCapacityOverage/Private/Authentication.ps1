function Invoke-OverageCliToken {
    param([string] $CommandPath)
    $savedPreference = $ErrorActionPreference
    try {
        # Windows PowerShell otherwise promotes native stderr to a terminating
        # error before we can inspect the exit code. Never log native output.
        $ErrorActionPreference = 'Continue'
        $nativeOutput = & $CommandPath account get-access-token --resource 'https://analysis.windows.net/powerbi/api' --output json --only-show-errors 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($exitCode -ne 0) {
        throw 'Azure CLI could not acquire a Power BI token. Run az login --tenant <tenant-id>.'
    }
    $result = ($nativeOutput -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
    $token = Get-OptionalProperty $result 'accessToken'
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'Azure CLI returned no access token.' }
    return [string] $token
}

function Get-OverageAccessToken {
    $failures = [System.Collections.Generic.List[string]]::new()
    $cli = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cli) {
        try {
            $token = Invoke-OverageCliToken -CommandPath $cli.Source
            Write-Verbose 'Authenticated through Azure CLI.'
            return $token
        }
        catch {
            $failures.Add('Azure CLI authentication failed; run az login --tenant <tenant-id>.')
            Write-Verbose $failures[$failures.Count - 1]
        }
    }
    try {
        $context = Get-AzContext -ErrorAction Stop
        if ($null -eq $context -or $null -eq $context.Account) {
            throw 'No authenticated Az.Accounts context.'
        }
        $result = Get-AzAccessToken -ResourceUrl 'https://analysis.windows.net/powerbi/api' -ErrorAction Stop
        if ($result.Token -is [System.Security.SecureString]) {
            $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($result.Token)
            try { $token = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
        }
        else { $token = [string] $result.Token }
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Az.Accounts returned no access token.' }
        Write-Verbose 'Authenticated through Az.Accounts.'
        return $token
    }
    catch {
        $failures.Add('Az.Accounts authentication failed. Run Connect-AzAccount -Tenant <tenant-id> in this session.')
        Write-Verbose 'Az.Accounts did not provide an authenticated Power BI token.'
    }
    throw ($failures -join [Environment]::NewLine)
}
