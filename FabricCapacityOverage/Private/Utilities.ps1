function Get-OptionalProperty {
    param([object] $InputObject, [string] $Name)
    if ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            if ($property.Value -is [array]) { return $property.Value }
            # Preserve enumerable metadata objects, such as HTTP headers.
            return ,$property.Value
        }
    }
}

function Get-QueryField {
    param([object] $Row, [string] $Name)
    foreach ($key in @("[$Name]", $Name)) {
        $property = $Row.PSObject.Properties[$key]
        if ($null -ne $property) { return $property.Value }
    }
    throw "Query result is missing '$Name'. The Metrics App schema or response is incompatible."
}

function ConvertTo-MetricNumber {
    param([object] $Value, [string] $Name)
    $number = [decimal] 0
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $text = [System.Convert]::ToString($Value, $culture)
    if ($null -eq $Value -or -not [decimal]::TryParse(
        $text, [System.Globalization.NumberStyles]::Float, $culture, [ref] $number
    ) -or $number -lt 0) {
        throw "Invalid or missing nonnegative numeric metric '$Name': '$text'. No cost was inferred."
    }
    return $number
}

function ConvertTo-ModelTime {
    param([object] $Value)
    $time = [datetime]::MinValue
    # REST clients can deserialize ISO strings. Preserve the app's clock,
    # including DateTimeOffset wall time, rather than the caller's timezone.
    if ($Value -is [datetime]) { $time = $Value }
    elseif ($Value -is [datetimeoffset]) { $time = $Value.DateTime }
    elseif (-not [datetime]::TryParseExact(
        [string] $Value, 'yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None, [ref] $time
    )) {
        throw "Invalid model timestamp '$Value'. Expected yyyy-MM-ddTHH:mm:ss in the app's clock."
    }
    return [datetime]::SpecifyKind($time, [System.DateTimeKind]::Unspecified)
}

function ConvertTo-DaxTime {
    param([datetime] $Time)
    return "DATE($($Time.Year),$($Time.Month),$($Time.Day)) + TIME($($Time.Hour),$($Time.Minute),$($Time.Second))"
}

function ConvertTo-RefreshUtcTime {
    param([object] $Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    $time = [datetimeoffset]::MinValue
    if ([string] $Value -notmatch '^\d{4}-\d{2}-\d{2}T' -or -not [datetimeoffset]::TryParse(
        [string] $Value, [System.Globalization.CultureInfo]::InvariantCulture,
        ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal),
        [ref] $time
    )) {
        throw "Invalid refresh-history UTC timestamp '$Value'. Refresh freshness was not inferred."
    }
    return $time.UtcDateTime
}

function Get-OverageUtcNow {
    return [datetime]::UtcNow
}
