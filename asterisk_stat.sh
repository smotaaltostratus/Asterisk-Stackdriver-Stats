#!/bin/bash
#
# ------------------------------------------------------------------------------
# REBTEL/SIPInfra Post metric to stackdriver GCP (BETA)
# ------------------------------------------------------------------------------
# This script is only intended as a cron job Scripts to post metrics into
# stackdriver GCP.
# It will run on all our media server instances to perform channels stats query
# using asterisk cli interface every 1 minute.
#
# Don't forget to give your instance gcp api access
#     "Cloud API access scopes ->  Stackdriver Monitoring API".
# ------------------------------------------------------------------------------
#
#  (c) 2018 Rebtel <oussama.hammami@rebtel.com>
#
#####################################################################

[[ "$TRACE" ]] && { set -x; set -o functrace; }

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
my_pid=$$

# SIPInfra parameters

gcp_project_id="rebtel-calling-infra-prod"
gcp_instance_id="prod-custom-image-eu-west3-a-v1"
gcp_zone="europe-west3-a"

#### NO CHANGES BELOW THIS LINE!

VERSION=0.0.2
MRC=0

# Lock the Scripts

[[ "$LOCKFILE" == "" ]] && LOCKFILE="/var/lock/`basename $0`"
LOCKFD=99

# PRIVATE
_lock()             { flock -$1 $LOCKFD; }
_no_more_locking()  { _lock u; _lock xn && rm -f $LOCKFILE; }
_prepare_locking()  { eval "exec $LOCKFD>\"$LOCKFILE\""; trap _no_more_locking EXIT; }

# ON START
_prepare_locking

# PUBLIC
exlock_now()        { _lock xn; }  # obtain an exclusive lock immediately or fail
exlock()            { _lock x; }   # obtain an exclusive lock
shlock()            { _lock s; }   # obtain a shared lock
unlock()            { _lock u; }   # drop a lock

# Simplest example is avoiding running multiple instances of script.
exlock_now || {
	echo "ERROR: `basename $0` already running!"
	exit 1
}

######################################################################
#
# Start of function definitions
#
######################################################################

is_root_user() {
  # Function to check that the effective user id of the user running
  # the script is indeed that of the root user (0)

  if [[ $EUID != 0 ]]; then
    return 1
  fi
  return 0
}

locate_cmd() {
  # Function to return the full path to the cammnd passed to us
  # Make sure it exists on the system first or else this exits
  # the script execution

  local cmd="$1"
  local valid_cmd=""

  # valid_cmd=$(hash -t $cmd 2>/dev/null)
  valid_cmd=$(command -v $cmd 2>/dev/null)
  if [[ ! -z "$valid_cmd" ]]; then
    echo "$valid_cmd"
  else
    echo "HALT: Please install package for command '$cmd'"
    /bin/kill -s TERM $my_pid
  fi
  return 0
}

check_status() {
  # Function to check and do something with the return code of some command

  local return_code="$1"

  if [[ $return_code != 0 ]]; then
    echo "HALT: Return code of command was '$return_code', aborting."
    echo "Please check the log above and correct the issue."
    exit 1
  fi
}

prepare_request() {
  # Function to prepare the request body of the curl request to gcp api

  local time_series_type=$1
  local time_series_value=$2
  local metric_type="custom.googleapis.com/"
  local cmd_date=$(locate_cmd "date")
  local time_series_endTime=$($cmd_date --utc +%FT%T.%3NZ)

  case "$time_series_type" in
    "active_calls"    ) metric_type="${metric_type}active_calls" ;;
    "active_channels" ) metric_type="${metric_type}active_channels" ;;
    "calls_processed" ) metric_type="${metric_type}calls_processed" ;;
    *                 ) metric_type=""    ;; # Unsupported call
  esac

  if [[ ! -z "$metric_type" ]]; then
    local request_body='{
    "timeSeries": [
      {
       "metric": {
        "type": "'$metric_type'"
       },
       "resource": {
        "type": "gce_instance",
        "labels": {
         "instance_id": "'$gcp_instance_id'",
         "zone": "'$gcp_zone'",
         "project_id": "'$gcp_project_id'"
        }
       },
       "points": [
        {
         "interval": {
          "endTime": "'$time_series_endTime'"
         },
         "value": {
          "doubleValue": '$time_series_value'
         }
        }
       ]
    }
  ]
}'
    echo "$request_body"
  else
    echo "HALT: GCP metric type '$metric_type' error !" >&2
    /bin/kill -s TERM $my_pid
    exit 1
  fi
  return 0
}

get_token(){
  # Function to get the authentification token for the gcp api
  # https://developers.google.com/identity/protocols/OAuth2InstalledApp
  local cmd_curl=$(locate_cmd "curl")
  local response_body=$($cmd_curl -s "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" -H "Metadata-Flavor: Google")
  local response_regexp="^.*\"access_token\":\"(.*)\".*\"expires_in\":([0-9]+).*$"

  if [[ $response_body =~ $response_regexp ]]; then
    local access_token=${BASH_REMATCH[1]}
    local expires_in=${BASH_REMATCH[2]}
    #if [[ "$expires_in" -ge "30" ]]; then
    #if [[ "$expires_in" -le "30" ]]; then
    if (( $expires_in > 15 )); then
      echo $access_token
    else
      local cmd_sleep=$(locate_cmd "sleep")
      MRC=$((MRC+1))
      $cmd_sleep $((expires_in+1))
      if (( $MRC < 2 )); then
        echo $(get_token)
      else
        echo "HALT: Max recursive calls reached $MRC ! GCP Request error '$response_body'" >&2
        /bin/kill -s TERM $my_pid
        exit 1
      fi
    fi
  else
    echo "HALT: GCP Request error '$response_body'" >&2
    /bin/kill -s TERM $my_pid
    exit 1
  fi
}

execute_request() {
  # Function to execute the google API POST request
  # https://cloud.google.com/monitoring/api/ref_v3/rest/v3/projects.timeSeries/create
  # POST https://monitoring.googleapis.com/v3/{name}/timeSeries
  local time_series_type=$1
  local time_series_value=$2
  local request_body=""
  case "$time_series_type" in
    "active_calls"    ) request_body=$(prepare_request "active_calls" $time_series_value) ;;
    "active_channels" ) request_body=$(prepare_request "active_channels" $time_series_value) ;;
    "calls_processed" ) request_body=$(prepare_request "calls_processed" $time_series_value) ;;
    *                 ) request_body=""    ;; # Unsupported call
  esac
  if [[ ! -z "$request_body" ]]; then
    local cmd_curl=$(locate_cmd "curl")
    local api_url="https://monitoring.googleapis.com/v3/projects/$gcp_project_id/timeSeries"
    local api_token=$(get_token)
    $cmd_curl -s --data "$request_body" $api_url  -H "Authorization":"Bearer $api_token" -H "Accept: application/json" -H "Content-Type:application/json"
    check_status "$?"
  else
    echo "HALT: GCP metadata '$metric_type' request error !" >&2
    /bin/kill -s TERM $my_pid
    exit 1
  fi
  return 0
}

asterisk_stat() {
  # This is the main app, get asterisk stat from cli
  local cmd_rm=$(locate_cmd "rm")
  $cmd_rm -rf "/usr/share/asterisk/static-http/current-status.html"

  local cmd_date=$(locate_cmd "date")

  local start_date=$($cmd_date '+%Y-%m-%d %H:%M:%S')
  echo  2>&1
  echo "######################################################################"
  echo "[$start_date] - Rebtel Stack Driver Stat: Start execution..."
  echo "######################################################################"
  echo  2>&1

  if ! is_root_user; then
    echo "ERROR: You must be the root user. Exiting..." 2>&1
    echo  2>&1
    exit 1
  fi

  local cmd_asterisk=$(locate_cmd "asterisk")
  local cmd_tail=$(locate_cmd "tail")
  local ast_data=$($cmd_asterisk -rx 'core show channels' | $cmd_tail -3)
  local ast_pjsip=$($cmd_asterisk -rx 'pjsip show version')
  local regexp_channels="^([0-9]+) active channel.{0,1}$"
  local regexp_calls="^([0-9]+) active call.{0,1}$"
  local regexp_processed="^([0-9]+) call.{0,1} processed$"
  local regexp_pjsip="^PJPROJECT version currently running against: ([0-9]+\.?[0-9]+\.?[0-9]+)$"

  if [[ $ast_pjsip =~ $regexp_pjsip ]] ; then
    local pjsip_version=${BASH_REMATCH[1]}
  else
    echo "ERROR: pjsip probably not loaded ! Exiting..." 2>&1
    echo  2>&1
    exit 1
  fi

  local cmd_wc=$(locate_cmd "wc")
  local ast_data_nbl=$($cmd_wc -l <<< "$ast_data")
  if [[ "$ast_data_nbl" != "3" ]] ; then
    echo "ERROR: asterisk channels stat wrong output ! Exiting..." 2>&1
    echo  2>&1
    exit 1
  fi

  if [[ !(-z "$ast_data") && !(-z $ast_pjsip) ]]; then
    echo '<!DOCTYPE HTML>
                    <html lang="en">
          <head>
          <meta charset="utf-8">
          <title>Asterisk Status Page</title>
          <meta name="viewport" content="width=device-width">
          <meta name="robots" content="noindex, nofollow">
          <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/twitter-bootstrap/3.3.7/css/bootstrap.min.css">
          </head>
          <body>
          <div class="container" style="width: 40%; margin:0 auto;">
          <div class="page-header">
                  <h1>
                          Asterisk Status Page
                  </h1>
          </div>
          <ul class="list-group">
                  <li class="list-group-item list-group-item-success">PJSIP version currently running '$pjsip_version'</li>
          ' > /usr/share/asterisk/static-http/current-status.html 2> /dev/null
    while read -r line; do
      if [[ $line =~ $regexp_channels ]] ; then
        execute_request "active_channels" ${BASH_REMATCH[1]} >/dev/null 2>&1
        echo '<li class="list-group-item">
          <span class="badge"><span class="glyphicon glyphicon-ok" aria-hidden="true"></span> '${BASH_REMATCH[1]}'</span>
          active channels</li>' >> /usr/share/asterisk/static-http/current-status.html 2> /dev/null
      else
        if [[ $line =~ $regexp_calls ]] ; then
          execute_request "active_calls" ${BASH_REMATCH[1]} >/dev/null 2>&1
          echo '<li class="list-group-item">
            <span class="badge"><span class="glyphicon glyphicon-ok" aria-hidden="true"></span> '${BASH_REMATCH[1]}'</span>
            active calls</li>' >> /usr/share/asterisk/static-http/current-status.html 2> /dev/null
        else
          if [[ $line =~ $regexp_processed ]] ; then
            execute_request "calls_processed" ${BASH_REMATCH[1]} >/dev/null 2>&1
            echo '<li class="list-group-item">
              <span class="badge"><span class="glyphicon glyphicon-ok" aria-hidden="true"></span> '${BASH_REMATCH[1]}'</span>
              calls processed</li>' >> /usr/share/asterisk/static-http/current-status.html 2> /dev/null
          fi
        fi
      fi
    done <<< "$ast_data"
    echo '</ul>
          <hr>
          <footer style="position: absolute;right: 0;bottom: 0;left: 0;padding: 1rem;background-color: #efefef;text-align: center;">
                  <p><a href="https://www.rebtel.com/en/">Rebtel SIP INFRA</a> &copy; 2018
                  <span class="text-muted">&nbsp;-&nbsp;Generated at '$start_date'</span></p>
          </footer>
          </div>
          </body>
          </html>' >> /usr/share/asterisk/static-http/current-status.html 2> /dev/null
  else
    echo "HALT: asterisk execute core show channels error !" >&2
    /bin/kill -s TERM $my_pid
    exit 1
  fi
  local time_series=$($cmd_date --utc +%FT%T.%3NZ)
  echo "$time_series: Asterisk stats exported successfully, ENJOY :)"
  exit 0
}

######################################################################
#
# End of function definitions
#
######################################################################

######################################################################
#
# Start of main script
#
######################################################################

# only allow root to run the script
[[ "$0" == "$BASH_SOURCE" ]] && asterisk_stat
