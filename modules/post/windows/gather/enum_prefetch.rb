##
# This file is part of the Metasploit Framework and may be subject to
# redistribution and commercial restrictions. Please see the Metasploit
# web site for more information on licensing and terms of use.
#   http://metasploit.com/
##

require 'msf/core'
require 'rex'
require 'msf/core/post/windows/registry'
require 'time'

class Metasploit3 < Msf::Post
        include Msf::Post::Windows::Priv
	
        def initialize(info={})
                super(update_info(info,
                        'Name'          =>      'Windows Gather Prefetch File Information',
                        'Description'   =>       %q{This module gathers prefetch file information from WinXP & Win7 systems.},
                        'License'       =>      MSF_LICENSE,
                        'Author'        =>      ['TJ Glad <fraktaali[at]gmail.com>'],
                        'Platform'      =>      ['win'],
                        'SessionType'   =>      ['meterpreter']
                ))

        end


  def prefetch_key_value()
    # Checks if Prefetch registry key exists and what value it has.
    reg_key = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\Session\ Manager\\Memory\ Management\\PrefetchParameters", KEY_READ)
    key_value = reg_key.query_value("EnablePrefetcher").data

    if key_value == 0
      print_error("EnablePrefetcher Value: (0) = Disabled (Non-Default).")
    elsif key_value == 1
      print_good("EnablePrefetcher Value: (1) = Application launch prefetching enabled (Non-Default).")
    elsif key_value == 2
      print_good("EnablePrefetcher Value: (2) = Boot prefetching enabled (Non-Default).")
    elsif key_value == 3
      print_good("EnablePrefetcher Value: (3) = Applaunch and boot enabled (Default Value).")
    else
      print_error("No value or unknown value. Results might vary.")
    end
      reg_key.close
  end

  def timezone_key_value(sysnfo)

    if sysnfo =~/(Windows 7)/
      reg_key = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation", KEY_READ)
      key_value = reg_key.query_value("TimeZoneKeyName").data
      if key_value.empty? or key_value.nil?
        print_line("Couldn't find key/value for timezone from registry.")
      else
        print_good("Remote: Timezone is %s" % key_value)
      end

    elsif sysnfo =~/(Windows XP)/
      reg_key = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation", KEY_READ)
      key_value = reg_key.query_value("StandardName").data
      if key_value.empty? or key_value.nil?
        print_line("Couldn't find key/value for timezone from registry.")
      else
        print_good("Remote: Timezone is %s" % key_value)
      end
    else
      print_error("Unknown system. Can't find timezone value from registry.")
    end
    reg_key.close
  end


  def timezone_bias()
    # Looks for the timezone difference in minutes from registry
    reg_key = session.sys.registry.open_key(HKEY_LOCAL_MACHINE, "SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation", KEY_READ)
    key_value = reg_key.query_value("Bias").data
    if key_value.nil?
      print_error("Couldn't find bias from registry")
    else
      if key_value < 0xfff
        bias = key_value
        print_good("Remote: localtime bias to UTC: -%s minutes." % bias)
      else
        offset = 0xffffffff
        bias = offset - key_value
        print_good("Remote: localtime bias to UTC: +%s minutes." % bias)
      end
    end
    reg_key.close
  end


  def gather_prefetch_info(name_offset, hash_offset, lastrun_offset, runcount_offset, filename, table)

    # This function seeks and gathers information from specific offsets.
    h = client.railgun.kernel32.CreateFileA(filename, "GENERIC_READ", "FILE_SHARE_DELETE|FILE_SHARE_READ|FILE_SHARE_WRITE", nil, "OPEN_EXISTING", "FILE_ATTRIBUTE_NORMAL", 0)

    if h['GetLastError'] != 0
      print_error("Error opening a file handle.")
      return nil
    else
      handle = h['return']

      # Finds the filename from the prefetch file
      client.railgun.kernel32.SetFilePointer(handle, name_offset, 0, nil)
      name = client.railgun.kernel32.ReadFile(handle, 60, 60, 4, nil)
      x = name['lpBuffer']
      pname = x.slice(0..x.index("\x00\x00"))

      # Finds the run count from the prefetch file 
      client.railgun.kernel32.SetFilePointer(handle, runcount_offset, 0, nil)
      count = client.railgun.kernel32.ReadFile(handle, 4, 4, 4, nil)
      prun = count['lpBuffer'].unpack('L*')[0]

      # Finds the hash.
      client.railgun.kernel32.SetFilePointer(handle, hash_offset, 0, 0)
      hh = client.railgun.kernel32.ReadFile(handle, 4, 4, 4, nil)
      phash = hh['lpBuffer'].unpack('h*')[0].reverse

      # Finds the LastModified timestamp (MACE)
      lm  = client.priv.fs.get_file_mace(filename)
      lmod = lm['Modified'].utc.to_s

      # Finds the Creation timestamp (MACE)
      cr = client.priv.fs.get_file_mace(filename)
      creat = cr['Created'].utc.to_s

      # Prints the results and closes the file handle
      if name.nil? or count.nil? or hh.nil? or lm.nil? or cr.nil?
        print_error("Could not access file: %s." % filename)
      else
        #print_line("%s\t\t%s\t\t%s\t%s\t%-30s" % [creat, lmod, prun, phash, pname])
        table << [lmod,creat,prun,phash,pname]
      end
      #print_line("%s\t\t%s\t\t%s\t%s\t%-30s" % [creat, lmod, prun, phash, pname])
      client.railgun.kernel32.CloseHandle(handle)
    end
  end



  def run

    print_status("Prefetch Gathering started.")

    if not is_admin?
      print_error("You don't have enough privileges. Try getsystem.")
      return nil
    end


    begin

    # Check to see what Windows Version is running.
    # Needed for offsets.
    # Tested on WinXP and Win7 systems. Should work on WinVista & Win2k3..
    # http://www.forensicswiki.org/wiki/Prefetch
    # http://www.forensicswiki.org/wiki/Windows_Prefetch_File_Format

    sysnfo = client.sys.config.sysinfo['OS']

    if sysnfo =~/(Windows XP)/ # Offsets for WinXP
      print_good("Detected Windows XP (max 128 entries)")
      name_offset = 0x10
      hash_offset = 0x4C
      lastrun_offset = 0x78
      runcount_offset = 0x90

    elsif sysnfo =~/(Windows 7)/ # Offsets for Win7
      print_good("Detected Windows 7 (max 128 entries)")
      name_offset = 0x10
      hash_offset = 0x4C
      lastrun_offset = 0x80
      runcount_offset = 0x98
    else
      print_error("No offsets for the target Windows version. Currently works on WinXP and Win7.")
      return nil
    end

    table = Rex::Ui::Text::Table.new(
      'Header'  => "Prefetch Information",
      'Indent'  => 1,
      'Width'   => 110,
      'Columns' =>
      [
        "Modified (mace)",
        "Created (mace)",
        "Run Count",
        "Hash",
        "Filename"
      ])

    print_status("Searching for Prefetch Registry Value.")

    prefetch_key_value

    print_status("Searching for TimeZone Registry Values.")

    timezone_key_value(sysnfo)
    timezone_bias

    print_good("Current UTC Time: %s" % Time.now.utc)

    sysroot = client.fs.file.expand_path("%SYSTEMROOT%")
    full_path = sysroot + "\\Prefetch\\"
    file_type = "*.pf"
    print_status("Gathering information from remote system. This will take awhile..")

    # Goes through the files in Prefetch directory, creates file paths for the
    # gather_prefetch_info function that enumerates all the pf info
    getfile_prefetch_filenames = client.fs.file.search(full_path,file_type,recurse=false,timeout=-1)
    getfile_prefetch_filenames.each do |file|
      if file.empty? or file.nil?
        print_error("Could not open file: %s." % file['name'])
      else
        filename = File.join(file['path'], file['name'])
        gather_prefetch_info(name_offset, hash_offset, lastrun_offset, runcount_offset, filename, table)
      end
    end
    end

    results = table.to_s
    loot = store_loot("prefetch_info", "text/plain", session, results, nil, "Prefetch Information")
    print_line("\n" + results + "\n")
    print_status("Finished gathering information from prefetch files.")
    print_status("Results stored in: #{loot}")
  end
end
