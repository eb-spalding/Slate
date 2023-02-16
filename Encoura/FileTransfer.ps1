#-----------------------------------------------------------------#
# User should update the values in the following block 
#-----------------------------------------------------------------#

# Encoura settings
$api_user = "support@university.edu"             # Encoura service account username
$api_password = "encoura_password"               # Encoura service account password
$api_key = "encoura_api_key"                     #Encoura API key
$api_url = "https://api.datalab.nrccua.org/v1"   #Encoura API url

# Slate settings
$slate_base_url = "https://apply.university.edu"   # Slate instance base URL
$slate_user = "slate_username"                     # Slate import user username
$slate_password = "slate_password"                 # Slate import user password

# List of report types to transfer from Encoura to Slate
# Each entry in the list should contain:
#    api_product_key: specifies which report type to download from encoura
#                     See the following URL for a list of avaialable Encoura product keys:
#                     https://helpcenter.encoura.org/hc/en-us/article_attachments/12417606808077/2022_File_Export_API_Documentation.pdf
#    slate_source_format_guid: specifies the GUID of the Slate Source Format that should
#                     be used to import the given report type
$report_types = @(
    @{api_product_key = "score-reporter"; slate_source_format_guid = "00000000-0000-0000-0000-000000000000" },
    @{api_product_key = "aos"; slate_source_format_guid = "12345678-0000-0000-0000-000000000000" }
)

#-----------------------------------------------------------------#
# User should not need to update anything below this point
#-----------------------------------------------------------------#

#-----------------------------------------------------------------#
# Get a JSON web token and organization ID from Encoura API
#-----------------------------------------------------------------#
$headers = @{"x-api-key" = $api_key }
$body = @{
    "userName"      = $api_user;
    "password"      = $api_password;
    "acceptedTerms" = $true
}
$result = Invoke-RestMethod "$($api_url)/login" -Method "POST" -Headers $headers -Body $body -SkipHttpErrorCheck -StatusCodeVariable "scv"
if ($scv -ne 200) {
    Write-Error "($($scv)) Unable to authenticate to Encoura with provided credentials."
    Exit
}
$token = $result.sessionToken
$org_id = $result.user.organizations[0].uid


#-----------------------------------------------------------------#
#Iterate over the list of report types to fetch from the api
#-----------------------------------------------------------------#
foreach ($report_type in $report_types) {
    #-----------------------------------------------------------------#
    # GET the list of available NotDelivered reports 
    # of the current report type
    #-----------------------------------------------------------------#
    $headers = @{
        "x-api-key"     = $api_key;
        "Authorization" = "JWT $($token)";
        "Organization"  = $org_id
    }
    $body = @{"status" = "NotDelivered"; "productKey" = $report_type.api_product_key }
    $result_list = Invoke-RestMethod "$($api_url)/datacenter/exports" -Body $body -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable "scv"
    if ($scv -ne 200) {
        Write-Warning "($($scv)) No new reports found"
        Exit
    }

    Write-Host "Found ${$result_list.Length} undelivered reports of type: $($report_type.api_product_key)."
    
    #-----------------------------------------------------------------#
    # Iterate over the list of discovered reports of the given type
    #-----------------------------------------------------------------#
    foreach ($current_item in $result_list) {
        Write-Host "Downloading report with uid $($report.uid)"

        #-----------------------------------------------------------------#
        # GET the AWS S3 URL for the score report
        #-----------------------------------------------------------------#
        $report_result = Invoke-RestMethod "$($api_url)/datacenter/exports/$($current_item.uid)/download" -Headers $headers -SkipHttpErrorCheck -StatusCodeVariable "scv"
        
        if ($scv -ne 200) {
            Write-Error "($($scv)) Failed to fetch report metadata for report with uid: $($current_item.uid))"
            Break
        }
        
        #-----------------------------------------------------------------#
        # GET the actual file from AWS
        #-----------------------------------------------------------------#
        $report_data = Invoke-RestMethod $report_result.downloadUrl -SkipHttpErrorCheck -StatusCodeVariable "scv"
        if ($scv -ne 200) {
            Write-Error "($($scv)) Failed to download report with uid: $($current_item.uid))"
            Break
        }

        #-----------------------------------------------------------------#
        # POST the downloaded report data to Slate
        #-----------------------------------------------------------------#
        Write-Host "Uploading report with uid $($current_item.uid)"
        $slate_sf_url = "$($slate_base_url)/manage/service/import?cmd=load&format=$($report_type.slate_source_format_guid)"
    
        $auth_value = "$($slate_user):$($slate_password)"
        $slate_headers = @{
            "Authorization" = "Bearer $([System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($auth_value)))";
        }
        Invoke-RestMethod $slate_sf_url -Method "POST" -Headers $slate_headers -Body $report_data -SkipHttpErrorCheck -StatusCodeVariable "scv"
        if ($scv -ne 200) {
            Write-Error "($($scv)) Failed to post report to Slate with uid: $($current_item.uid))"
            Break
        }
    }
}