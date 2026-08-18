-- Claude Session Restorer
-- Pick which recorded Claude Code sessions to reopen, and how (separate windows vs tabs).

on run
	set homePath to POSIX path of (path to home folder)
	set listScript to homePath & ".claude/scripts/claude-session-list.sh"
	set claudeBin to do shell script "command -v claude 2>/dev/null || echo claude"

	set rawData to ""
	try
		set rawData to do shell script "/bin/bash " & quoted form of listScript
	end try
	if rawData is "" then
		display dialog "No recent Claude sessions found." buttons {"OK"} default button "OK" with icon note
		return
	end if

	set idList to {}
	set dirList to {}
	set displayList to {}

	-- `do shell script` returns CR-separated output; `paragraphs` handles CR/LF/CRLF.
	set theLines to paragraphs of rawData

	repeat with ln in theLines
		set ln to ln as text
		if ln is not "" then
			set AppleScript's text item delimiters to tab
			set parts to text items of ln
			set AppleScript's text item delimiters to ""
			if (count of parts) is greater than or equal to 3 then
				set theId to item 1 of parts
				set theDir to item 2 of parts
				set theDisplay to item 3 of parts
				set end of idList to theId
				set end of dirList to theDir
				set end of displayList to theDisplay
			end if
		end if
	end repeat

	set chosen to choose from list displayList with title "Claude Session Restorer" with prompt "Select the sessions to reopen:" OK button name "Next" cancel button name "Cancel" with multiple selections allowed
	if chosen is false then return

	set modeChoice to choose from list {"Separate windows (one per session)", "Tabs in a single window"} with title "Window layout" with prompt "How should they open?" default items {"Separate windows (one per session)"} OK button name "Restore" cancel button name "Cancel"
	if modeChoice is false then return
	set sepWindows to ((item 1 of modeChoice) starts with "Separate")

	set madeFirst to false
	repeat with c in chosen
		set c to c as text
		repeat with i from 1 to count of displayList
			if item i of displayList is c then
				my openSession(item i of idList, item i of dirList, claudeBin, sepWindows, madeFirst)
				set madeFirst to true
				exit repeat
			end if
		end repeat
	end repeat
end run

on openSession(theId, theDir, claudeBin, sepWindows, madeFirst)
	set AppleScript's text item delimiters to "/"
	set dirParts to text items of theDir
	set AppleScript's text item delimiters to ""
	set theName to item -1 of dirParts
	set b64 to do shell script "printf %s " & quoted form of theName & " | base64"
	set prelude to "printf '\\033]1337;SetBadgeFormat=%s\\a' '" & b64 & "'; printf '\\033]0;%s\\a' '" & theName & "'; "
	set cmd to prelude & "cd '" & theDir & "' && " & claudeBin & " --resume " & theId
	tell application "iTerm2"
		activate
		if sepWindows then
			create window with default profile
			tell current session of current window
				set name to theName
				write text cmd
			end tell
		else
			if madeFirst is false then
				create window with default profile
				tell current session of current window
					set name to theName
					write text cmd
				end tell
			else
				tell current window
					create tab with default profile
					tell current session
						set name to theName
						write text cmd
					end tell
				end tell
			end if
		end if
	end tell
end openSession