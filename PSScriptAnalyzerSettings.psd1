# PSScriptAnalyzer settings for ManoSegura.
# All default rules apply (Error and Warning) except those justified below:
#  - PSAvoidUsingPositionalParameters: the CLI calls its own small helpers positionally
#    on purpose (keeps the single file readable). External cmdlets are called by name.
#  - PSUseShouldProcessForStateChangingFunctions: several helpers change only ManoSegura's
#    own state files (disabled.flag, trust.txt, target.txt), not user data.
#  - PSUseSingularNouns: Get-ManoWindows / Get-ManoMonitors return a list by design.
#  - PSAvoidUsingEmptyCatchBlock: best-effort cleanup around Win32/WinForms calls
#    (a failure there must never stop a panic or an overlay refresh).
#  - PSUseApprovedVerbs: domain verbs Ensure-/Throw-/Focus-/Prepare- are deliberate.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingPositionalParameters'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseApprovedVerbs'
    )
}
