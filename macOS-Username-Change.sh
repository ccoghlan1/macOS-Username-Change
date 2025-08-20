#!/bin/bash

## Written by Ciaran Coghlan c.coghlan@mdsuae.ae
## Date July 2025
##
## This script will read the username in Jamf Pro and use that to set the computers home directory name and username
## This script is written to make use of the Jamf Pro API. It requires the Read Computers API privileges
## The script can be scoped to All Managed Clients, it will not modify anything if the local username matches Jamf Pro
## If there is no user in Jamf Pro the script will exit with an error, check the Policy logs for these

################################################################################################
## DISCLAIMER
################################################################################################
## This script is provided "AS IS" without warranty of any kind, express or implied,
## including but not limited to the warranties of merchantability, fitness for a
## particular purpose, and noninfringement. The authors and distributors of this script
## make no guarantees regarding its suitability, reliability, availability, or
## performance. While the script has been tested in various scenarios, no assurance is
## given that it will cover all use cases or operate error-free in every environment.
##
## By using this script, you acknowledge and agree that you do so at your own risk.
## In no event shall the authors, contributors, or associated organisations be held
## liable for any damages, including but not limited to direct, indirect, incidental,
## consequential, or special damages, or loss of data, profits, or business, arising
## from the use of or inability to use this script, even if advised of the possibility
## of such damages.
##
##			If you do not agree to these terms, please do not use this script.
##

################################################################################################
# Variables
################################################################################################

## User Set Variables (Update these to match your Jamf Pro Instance)
url="https://yourjamfserver.jamfcloud.com"
client_id="clientid here"
client_secret="client secret here"

## Standard Variables
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"

## Gather Existing user information
currentSerial=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')
readonly currentUser=$(stat -f%Su /dev/console)
readonly currenthome=$(dscl . read "/Users/$currentUser" NFSHomeDirectory | awk '{print $2}' -)
readonly currentrecordname=$(dscl . read "/Users/$currentUser" RecordName | sed 's/^RecordName: //')
readonly currentrealname=$(dscl . read "/Users/$currentUser" RealName | tail -n +2)

################################################################################################
# Functions
################################################################################################

## Get Access Token
getAccessToken() {
	response=$(curl -s \
	--request POST "$url/api/oauth/token" \
	--header 'Content-Type: application/x-www-form-urlencoded' \
	--data-urlencode "client_id=$client_id" \
	--data-urlencode 'grant_type=client_credentials' \
	--data-urlencode "client_secret=$client_secret")
	access_token=$(echo "$response" | plutil -extract access_token raw -)
	token_expires_in=$(echo "$response" | plutil -extract expires_in raw -)
	current_epoch=$(date +%s)
	token_expiration_epoch=$(($current_epoch + $token_expires_in))
}

loginfo() {
	value="$1"
	timestamp=$(date "+%Y-%m-%d %H:%M:%S")
	
	echo "[LOGGING] [$timestamp] "$value""
}

updateusername() {
	## This function makes the actual name and path changes.
	
	## Change the users home directory path
	## This is where we are most likely to encounter an error, we run this first to limit changes that may need to be reverted.
	
	## Confirm that the Jamf user doesnt already exist
	if [[ -d "/Users/$jamfusername" ]]; then
		loginfo "There is already a home directory /Users/$jamfusername. Exiting without making changes"
		
		notifyfailure
		exit 1
	fi
	
	## Changing the home directory path
	loginfo "Changing the users home path from $currenthome to /Users/$jamfusername"
	mv "$currenthome" "/Users/$jamfusername"
	
	## Confirm home change was successful
	if [[ $? -ne 0 ]]; then
		loginfo "Could not rename the home directory - error code:$?"
		
		## Revert the home directory changes, first check that the name was actually changed.
		if [[ -d "$currenthome" ]]; then
			loginfo "The home directory was not renamed, exiting without changing it"
			
			notifyfailure
			exit 1
		fi
		
		## Change the name back if it was changed.
		loginfo "Changing back the home directory to $currenthome"
		mv "/Users/$jamfusername" "$currenthome"
		
		notifyfailure
		exit 1
	fi
	
	## Change the Real Name
	loginfo "updating the computer RealName to $jamfrealname"
	dscl . create /Users/"$currentUser" RealName "$jamfrealname"
	
	## Confirm RealName Change was successful
	if [[ $? -ne 0 ]]; then
		loginfo "Could not change the RealName - error code:$?"
		loginfo "Changing back the Real Name to $currentrealname"
		
		## Revert change
		dscl . create "/Users/$currentUser" RealName "$currentrealname"
		
		## Revert the home directory changes, first check that the name was actually changed.
		if [[ -d "$currenthome" ]]; then
			loginfo "The home directory was not renamed, exiting without changing it"
			
			notifyfailure
			exit 1
		fi
		
		## Change the name back if it was changed.
		loginfo "Changing back the home directory to $currenthome"
		mv "/Users/$jamfusername" "$currenthome"
		
		notifyfailure
		exit 1

	fi
	
	## Change the RecordName 
	loginfo "updating the computer RecordName to $jamfusername"
	dscl . create /Users/"$currentUser" RecordName "$jamfusername"
	
	## Confirm RecordName change was successful
	if [[ $? -ne 0 ]]; then
		loginfo "Could not change the RecordName - error code:$?"
		loginfo "Changing back the RecordName to $currentrecordname and RealName to $currentrealname"
		
		# Revert changes
		dscl . create "/Users/$currentUser" RecordName "$currentrecordname"
		dscl . create "/Users/$currentUser" RealName "$currentrealname"
		
		## Revert the home directory changes, first check that the name was actually changed.
		if [[ -d "$currenthome" ]]; then
			loginfo "The home directory was not renamed, exiting without changing it"
			
			notifyfailure
			exit 1
		fi
		
		## Change the name back if it was changed.
		loginfo "Changing back the home directory to $currenthome"
		mv "/Users/$jamfusername" "$currenthome"
		
		notifyfailure
		exit 1
	fi
	
	## Update the NFSHomeDirectory value to the new home directory.
	loginfo "updating the user NFSHomeDirectory to /Users/$jamfusername"
	dscl . create "/Users/$jamfusername" NFSHomeDirectory "/Users/$jamfusername"
	
	## Confirm NFSHomeDirectory change was successful
	if [[ $? -ne 0 ]]; then
		loginfo "Could not change the NFSHomeDirectory - error code:$?"
		loginfo "Changing back the RecordName to $currentrecordname and RealName to $currentrealname"
		
		## Revert earlier changes
		dscl . create "/Users/$currentUser" RecordName "$currentrecordname"
		dscl . create "/Users/$currentUser" RealName "$currentrealname"
		
		## Revert NFSHomeDirectory Change
		loginfo "Changing back the NFSHomeDirectory to $currenthome"
		dscl . create "/Users/$currentUser" NFSHomeDirectory "$currenthome"
		
		## Revert the home directory changes, first check that the name was actually changed.
		if [[ -d "$currenthome" ]]; then
			loginfo "The home directory was not renamed, exiting without changing it"
			
			notifyfailure
			exit 1
		fi
		
		## Change the name back if it was changed.
		loginfo "Changing back the home directory to $currenthome"
		mv "/Users/$jamfusername" "$currenthome"
		
		notifyfailure
		exit 1
	fi

	## Link old home directory to the new one.
	loginfo "Creating a link from the new home directory /Users/$jamfusername to the old directory $currenthome"
	ln -s "/Users/$jamfusername" "$currenthome"
	
	## Log success
	loginfo "The records have been successfully updated. Original Username:"$currentrecordname", Original Real Name:"$currentrealname", Original Home Path:"$currenthome" ========= New Username:"$jamfusername", New Real Name:"$jamfrealname", new Home Path:"/Users/$jamfusername""
}

promptuser() {
	## This will prompt the user to close what they have open, this is important since its not possible to save once the home directory changes.
	
	userconfirmation=$("$jamfHelper" -description "Your username is going to change from "$currentUser" to "$jamfusername", any files you don't save now will be lost. You will not be prompted after this point. Your computer will restart in about 30 seconds." -icon "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns" -windowType utility -heading "Save your work!" -button1 "I have saved" -title "Attention")
	
}

notifyfailure(){
	## This will notify the user that there has been a failure with the name change.
	
	"$jamfHelper" -description "We encountered an error changing your username, please reach out to IT. You may continue to work while the issue is investigated." -icon "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns" -windowType utility -heading "Error Changing Username" -button1 "I understand" -title "Error"
}

################################################################################################
# Main Script
################################################################################################

## Request a bearer token to use for the API call
loginfo "Generating a bearer token for the API call"
getAccessToken

## Perform the API call and get details for the current device serial
loginfo "Making an API call to get user information in Jamf Pro"
deviceDetails=$(curl -s -H "Authorization: Bearer $access_token" -H "Accept: application/xml" "$url/JSSResource/computers/match/$currentSerial")

## Extract from the API call the username record in Jamf, this assumes email is mapped to username, we remove the domain here
readonly jamfusername=$(echo "$deviceDetails" | xmllint --xpath "//computers/computer/username/text()" - | cut -d'@' -f1)

## Confirm if there is a username value in Jamf Pro
if [[ -z "$jamfusername" ]]; then
	loginfo "There is no username set in Jamf Pro, Exiting. Please set a username in the device inventory record"
	
	notifyfailure
	exit 1
fi

## Extract from the API call the Real Name record in Jamf
jamfrealname=$(echo "$deviceDetails" | xmllint --xpath "//computers/computer/realname/text()" -)

## Log the current user
loginfo "The original local user is $currentUser"

## Log the current RecordName
loginfo "The original RecordName is $currentrecordname"

## Log the current RealName
loginfo "The original RealName is $currentrealname"

## Log the current NFSHomeDirectory
loginfo "The original NFSHomeDirectory is $currenthome"

## Display the username that was found
loginfo "The username in Jamf is $jamfusername"

## Display the Realname that was found
loginfo "The Full Name in Jamf is $jamfrealname"

## Compare if the jamf user and local user match, if the dont match update the records

if [[ $currentUser != $jamfusername ]]; then
	
	## Prompt the user to save their informration
	loginfo "Notifying the user that they need to save their work"
	promptuser
	
	## Correct the username difference
	loginfo "The local username doesn't match the Jamf username, correcting"
	updateusername 
	
	## Submit inventory to Jamf Pro
	loginfo "Performing an inventory update to Jamf Pro"
	jamf recon
	
	## Reboot the computer
	loginfo "Restarting the computer in 5 seconds"
	shutdown -r +5s
	exit 0
	
else
	
	## If the usernames match already, do nothing
	loginfo "The local username matches the Jamf username. Exiting 0"
	exit 0
	
fi