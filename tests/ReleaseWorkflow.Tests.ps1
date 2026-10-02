BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:SignWorkflow = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\sign-module.yml') -Raw
    $script:PublishWorkflow = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\publish-module.yml') -Raw
    $script:ValidationWorkflow = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\validate.yml') -Raw
    $script:Pins = Import-PowerShellDataFile (Join-Path $script:Root 'scripts\Release\ActionPins.psd1')
}

Describe 'Manual-only protected release workflow invariants' {
    It 'has exactly workflow_dispatch as the signing/publishing trigger, never tags/push/PR/workflow_run' {
        foreach ($workflow in @($script:SignWorkflow, $script:PublishWorkflow)) {
            $workflow | Should -Match '(?m)^on:\r?\n  workflow_dispatch:'
            $workflow | Should -Not -Match '(?m)^  (push|pull_request|pull_request_target|workflow_run|release|schedule):'
            $workflow | Should -Match 'GITHUB_REF -cne ''refs/heads/main'''
            $workflow | Should -Match 'DEFAULT_BRANCH -cne ''main'''
            $workflow | Should -Match 'ref: \$\{\{ github.sha \}\}'
            $workflow | Should -Match 'persist-credentials: false'
        }
        $script:SignWorkflow | Should -Not -Match '(?m)^    inputs:'
        $script:PublishWorkflow | Should -Match 'signing_run_id:\r?\n\s+description:'
        $script:PublishWorkflow | Should -Match 'SIGNING_RUN_ID: \$\{\{ inputs.signing_run_id \}\}'
        $script:PublishWorkflow | Should -Not -Match 'run:.*\$\{\{ inputs\.'
    }

    It 'keeps Azure OIDC isolated to artifact-signing and the Gallery key to the final publish step' {
        $script:SignWorkflow | Should -Match 'environment: artifact-signing'
        $script:SignWorkflow | Should -Match '(?m)^      id-token: write\r?$'
        $script:SignWorkflow | Should -Not -Match 'PSGALLERY_API_KEY'
        $script:PublishWorkflow | Should -Match 'environment: powershell-gallery'
        $script:PublishWorkflow | Should -Match '(?m)^      contents: read\r?$'
        $script:PublishWorkflow | Should -Match '(?m)^      actions: read\r?$'
        $script:PublishWorkflow | Should -Not -Match 'id-token:|azure/login@|AZURE_CLIENT|AZURE_TENANT|AZURE_SUBSCRIPTION'
        ([regex]::Matches($script:PublishWorkflow, 'PSGALLERY_API_KEY:')).Count | Should -Be 1
        $script:PublishWorkflow | Should -Match 'PSGALLERY_API_KEY: \$\{\{ secrets.PSGALLERY_API_KEY \}\}'
        $script:ValidationWorkflow | Should -Not -Match 'id-token:|azure/login@|artifact-signing-action@|PSGALLERY_API_KEY'
    }

    It 'pins every release and validation action to a resolved official full SHA' {
        foreach ($workflow in @($script:SignWorkflow, $script:PublishWorkflow, $script:ValidationWorkflow)) {
            foreach ($match in [regex]::Matches($workflow, 'uses: ([A-Za-z0-9-]+/[A-Za-z0-9-]+)@([^\s]+)')) {
                $name = $match.Groups[1].Value
                $sha = $match.Groups[2].Value
                $sha | Should -Match '^[a-f0-9]{40}$'
                $script:Pins.ContainsKey($name) | Should -BeTrue
                $sha | Should -Be $script:Pins[$name].SHA
            }
        }
    }

    It 'uses CLI-only credentials, no secret fallback, no signing cache, explicit SHA256 and RFC3161' {
        foreach ($credential in @('environment', 'workload-identity', 'managed-identity', 'shared-token-cache',
            'visual-studio', 'visual-studio-code', 'azure-powershell', 'azure-developer-cli', 'interactive-browser')) {
            $script:SignWorkflow | Should -Match "exclude-$credential-credential: true"
        }
        $script:SignWorkflow | Should -Match 'exclude-azure-cli-credential: false'
        $script:SignWorkflow | Should -Match 'files-folder-filter: ps1,psm1,psd1'
        $script:SignWorkflow | Should -Match 'files-folder-recurse: true'
        $script:SignWorkflow | Should -Match 'file-digest: SHA256'
        $script:SignWorkflow | Should -Match 'timestamp-rfc3161: http://timestamp.acs.microsoft.com'
        $script:SignWorkflow | Should -Match 'timestamp-digest: SHA256'
        $script:SignWorkflow | Should -Match 'cache-dependencies: false'
        $script:SignWorkflow | Should -Match 'trace: false'
        $script:SignWorkflow | Should -Not -Match 'client-secret|AZURE_CREDENTIALS|thumbprint'
    }

    It 'uploads immutable bounded-retention artifacts and serializes publication without cancellation' {
        $script:SignWorkflow | Should -Match 'overwrite: false'
        $script:SignWorkflow | Should -Match 'retention-days: 7'
        $script:PublishWorkflow | Should -Match 'overwrite: false'
        $script:PublishWorkflow | Should -Match 'group: powershell-gallery-FabricCapacityOverage'
        $script:PublishWorkflow | Should -Match 'cancel-in-progress: false'
        $script:SignWorkflow | Should -Match 'Signing run ID: \$env:GITHUB_RUN_ID'
        $script:SignWorkflow | Should -Match 'GITHUB_STEP_SUMMARY'
    }

    It 'publishing verifies before the secret step and never builds, signs, fetches arbitrary refs or logs secrets' {
        $script:PublishWorkflow.IndexOf('Receive-SigningRelease.ps1') | Should -BeLessThan $script:PublishWorkflow.IndexOf('PSGALLERY_API_KEY:')
        $script:PublishWorkflow | Should -Not -Match 'Build-Package|Compress-PSResource|Complete-SigningRelease|Stage-Release|ref:.*inputs'
        $publisher = Get-Content -LiteralPath (Join-Path $script:Root 'scripts\Release\Services.ps1') -Raw
        $publisher | Should -Match 'Publish-PSResource -NupkgPath'
        $publisher | Should -Not -Match 'Publish-PSResource -Path'
        $publisher | Should -Not -Match '(Write-Host|Write-Output|Write-Verbose|Write-Warning).*PSGALLERY_API_KEY'
    }
}
