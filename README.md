# AppleCrashScripts

convertFromJSON.swift
- script for converting .ips files from new Apple JSON Crash format (used on iOS15 devices) to old style type crash report:

`swift convertFromJSON.swift -i {your_json_ips_file} -o {name_for_file_where_crash_will_be_saved}`

symbolicate.swift
- script symbolicates crash report. It looks for the right dSYM files itself - you don't have to specify which one to use. Especially useful when you have a lof of dSYM files and you don't remember which one is the one. Simply put the script on the file system in the same directory where dSYM files are stored(unzipped!). Then call the script telling which crash report you want to symbolicate:

`swift symbolicate.swift -crash {your_crash_file_name}`

## Documentation
The Apple crash report fields are described in [official article](https://developer.apple.com/documentation/xcode/examining-the-fields-in-a-crash-report)

As Apple likes to remove docs, the copy can be found [here](./docs/apple_crash_report_format.pdf) 
