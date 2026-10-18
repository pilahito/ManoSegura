# PSScriptAnalyzer settings for ManoSegura.
# All default rules apply (Error, Warning and Information) except:
#  - PSAvoidUsingPositionalParameters: the script calls its OWN small helper functions positionally
#    (e.g. Get-ManoResult 'click' "..."), which keeps the single file readable. Cmdlets are called by name.
@{
  Severity     = @('Error', 'Warning', 'Information')
  ExcludeRules = @('PSAvoidUsingPositionalParameters')
}
