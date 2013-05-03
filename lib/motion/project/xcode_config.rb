# Copyright (c) 2012, HipByte SPRL and contributors
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

module Motion; module Project;
  class XcodeConfig < Config
    variable :xcode_dir, :sdk_version, :deployment_target, :frameworks,
      :weak_frameworks, :framework_search_paths, :libs, :resources_dirs,
      :identifier, :codesign_certificate, :provisioning_profile,
      :short_version, :icons, :prerendered_icon, :seed_id, :entitlements,
      :fonts, :delegate_class

    def initialize(project_dir, build_mode)
      super
      @info_plist = {}
      @dependencies = {}
      @frameworks = []
      @weak_frameworks = []
      @framework_search_paths = []
      @libs = []
      @bundle_signature = '????'
      @short_version = '1'
      @icons = []
      @prerendered_icon = false
      @vendor_projects = []
      @entitlements = {}
      @delegate_class = 'AppDelegate'
      @spec_mode = false
    end

    def xcode_dir
      @xcode_dir ||= begin
        xcode_dot_app_path = '/Applications/Xcode.app/Contents/Developer'

        # First, honor /usr/bin/xcode-select
	xcodeselect = '/usr/bin/xcode-select'
        if File.exist?(xcodeselect)
          path = `#{xcodeselect} -print-path`.strip
          if path.match(/^\/Developer\//) and File.exist?(xcode_dot_app_path)
            @xcode_error_printed ||= false
            $stderr.puts(<<EOS) unless @xcode_error_printed
===============================================================================
It appears that you have a version of Xcode installed in /Applications that has
not been set as the default version. It is possible that RubyMotion may be
using old versions of certain tools which could eventually cause issues.

To fix this problem, you can type the following command in the terminal:
    $ sudo xcode-select -switch /Applications/Xcode.app/Contents/Developer
===============================================================================
EOS
            @xcode_error_printed = true
          end
          return path if File.exist?(path)
        end

        # Since xcode-select is borked, we assume the user installed Xcode
        # as an app (new in Xcode 4.3).
        return xcode_dot_app_path if File.exist?(xcode_dot_app_path)

        App.fail "Can't locate any version of Xcode on the system."
      end
      unescape_path(@xcode_dir)
    end

    def xcode_version
      @xcode_version ||= begin
        txt = `#{locate_binary('xcodebuild')} -version`
        vers = txt.scan(/Xcode\s(.+)/)[0][0]
        build = txt.scan(/Build version\s(.+)/)[0][0]
        [vers, build]
      end
    end

    def platforms; raise; end
    def local_platform; raise; end
    def deploy_platform; raise; end

    def validate
      # Xcode version
      App.fail "Xcode 4.x or greater is required" if xcode_version[0] < '4.0'

      # sdk_version
      platforms.each do |platform|
        sdk_path = File.join(platforms_dir, platform + '.platform',
            "Developer/SDKs/#{platform}#{sdk_version}.sdk")
        unless File.exist?(sdk_path)
          App.fail "Can't locate #{platform} SDK #{sdk_version} at `#{sdk_path}'" 
        end
      end

      # deployment_target
      if deployment_target > sdk_version
        App.fail "Deployment target `#{deployment_target}' must be equal or lesser than SDK version `#{sdk_version}'"
      end
      unless File.exist?(datadir)
        App.fail "iOS deployment target #{deployment_target} is not supported by this version of RubyMotion"
      end

      # icons
      if !(icons.is_a?(Array) and icons.all? { |x| x.is_a?(String) })
        App.fail "app.icons should be an array of strings."
      end

      super
    end

    def platforms_dir
      File.join(xcode_dir, 'Platforms')
    end

    def platform_dir(platform)
      File.join(platforms_dir, platform + '.platform')
    end

    def sdk_version
      @sdk_version ||= begin
        versions = Dir.glob(File.join(platforms_dir, "#{deploy_platform}.platform/Developer/SDKs/#{deploy_platform}*.sdk")).map do |path|
          File.basename(path).scan(/#{deploy_platform}(.*)\.sdk/)[0][0]
        end
        if versions.size == 0
          App.fail "Can't find an iOS SDK in `#{platforms_dir}'"
        end
        supported_vers = supported_sdk_versions(versions)
        unless supported_vers
          App.fail "RubyMotion doesn't support any of these SDK versions: #{versions.join(', ')}"
        end
        supported_vers
      end
    end

    def deployment_target
      @deployment_target ||= sdk_version
    end

    def sdk(platform)
      path = File.join(platform_dir(platform), 'Developer/SDKs',
        platform + sdk_version + '.sdk')
      escape_path(path)
    end

    def frameworks_dependencies
      @frameworks_dependencies ||= begin
        # Compute the list of frameworks, including dependencies, that the project uses.
        deps = frameworks.dup.uniq
        slf = File.join(sdk(local_platform), 'System', 'Library', 'Frameworks')
        deps.each do |framework|
          framework_path = File.join(slf, framework + '.framework', framework)
          if File.exist?(framework_path)
            `#{locate_binary('otool')} -L \"#{framework_path}\"`.scan(/\t([^\s]+)\s\(/).each do |dep|
              # Only care about public, non-umbrella frameworks (for now).
              if md = dep[0].match(/^\/System\/Library\/Frameworks\/(.+)\.framework\/(Versions\/.\/)?(.+)$/) and md[1] == md[3]
                deps << md[1]
                deps.uniq!
              end
            end
          end
        end

        if @framework_search_paths.empty?
          deps = deps.select { |dep| File.exist?(File.join(datadir, 'BridgeSupport', dep + '.bridgesupport')) }
        end
        deps
      end
    end

    def frameworks_stubs_objects(platform)
      stubs = []
      (frameworks_dependencies + weak_frameworks).uniq.each do |framework|
        stubs_obj = File.join(datadir, platform, "#{framework}_stubs.o")
        stubs << stubs_obj if File.exist?(stubs_obj)
      end
      stubs
    end

    def bridgesupport_files
      @bridgesupport_files ||= begin
        bs_files = []
        deps = ['RubyMotion'] + (frameworks_dependencies + weak_frameworks).uniq
        deps << 'UIAutomation' if spec_mode
        deps.each do |framework|
          supported_versions.each do |ver|
            next if ver < deployment_target || sdk_version < ver
            bs_path = File.join(datadir(ver), 'BridgeSupport', framework + '.bridgesupport')
            if File.exist?(bs_path)
              bs_files << bs_path
            end
          end
        end
        bs_files
      end
    end

    def default_archs
      h = {}
      platforms.each do |platform|
        h[platform] = Dir.glob(File.join(datadir, platform, '*.bc')).map do |path|
          path.scan(/kernel-(.+).bc$/)[0][0]
        end
      end
      h
    end

    def archs
      @archs ||= default_archs
    end

    def arch_flags(platform)
      archs[platform].map { |x| "-arch #{x}" }.join(' ')
    end

    def common_flags(platform)
      "#{arch_flags(platform)} -isysroot \"#{unescape_path(sdk(platform))}\" -F#{sdk(platform)}/System/Library/Frameworks"
    end

    def cflags(platform, cplusplus)
      "#{common_flags(platform)} -fexceptions -fblocks" + (cplusplus ? '' : ' -std=c99')
    end

    def ldflags(platform)
      common_flags(platform)
    end

    def bundle_name
      @name + (spec_mode ? '_spec' : '')
    end

    def app_bundle_dsym(platform)
      File.join(versionized_build_dir(platform), bundle_name + '.dSYM')
    end

    def archive
      File.join(versionized_build_dir(deploy_platform), bundle_name + '.ipa')
    end

    def identifier
      @identifier ||= "com.yourcompany.#{@name.gsub(/\s/, '')}"
      spec_mode ? @identifier + '_spec' : @identifier
    end

    def info_plist
      @info_plist
    end

    def dt_info_plist
      {}
    end

    def generic_info_plist
      {
        'BuildMachineOSBuild' => `sw_vers -buildVersion`.strip,
        'CFBundleDevelopmentRegion' => 'en',
        'CFBundleName' => @name,
        'CFBundleDisplayName' => @name,
        'CFBundleIdentifier' => identifier,
        'CFBundleExecutable' => @name, 
        'CFBundleInfoDictionaryVersion' => '6.0',
        'CFBundlePackageType' => 'APPL',
        'CFBundleShortVersionString' => @short_version,
        'CFBundleSignature' => @bundle_signature,
        'CFBundleVersion' => @version
      }
    end

    def pkginfo_data
      "AAPL#{@bundle_signature}"
    end

    def codesign_certificate
      @codesign_certificate ||= begin
        cert_type = (distribution_mode ? 'Distribution' : 'Developer')
        certs = `/usr/bin/security -q find-certificate -a`.scan(/"iPhone #{cert_type}: [^"]+"/).uniq
        if certs.size == 0
          App.fail "Can't find an iPhone Developer certificate in the keychain"
        elsif certs.size > 1
          App.warn "Found #{certs.size} iPhone Developer certificates in the keychain. Set the `codesign_certificate' project setting. Will use the first certificate: `#{certs[0]}'"
        end
        certs[0][1..-2] # trim trailing `"` characters
      end 
    end

    def provisioning_profile(name = /iOS Team Provisioning Profile/)
      @provisioning_profile ||= begin
        paths = Dir.glob(File.expand_path("~/Library/MobileDevice/Provisioning\ Profiles/*.mobileprovision")).select do |path|
          text = File.read(path)
          text.force_encoding('binary') if RUBY_VERSION >= '1.9.0'
          text.scan(/<key>\s*Name\s*<\/key>\s*<string>\s*([^<]+)\s*<\/string>/)[0][0].match(name)
        end
        if paths.size == 0
          App.fail "Can't find a provisioning profile named `#{name}'"
        elsif paths.size > 1
          App.warn "Found #{paths.size} provisioning profiles named `#{name}'. Set the `provisioning_profile' project setting. Will use the first one: `#{paths[0]}'"
        end
        paths[0]
      end
    end

    def read_provisioned_profile_array(key)
      text = File.read(provisioning_profile)
      text.force_encoding('binary') if RUBY_VERSION >= '1.9.0'
      text.scan(/<key>\s*#{key}\s*<\/key>\s*<array>(.*?)\s*<\/array>/m)[0][0].scan(/<string>(.*?)<\/string>/).map { |str| str[0].strip }
    end
    private :read_provisioned_profile_array

    def provisioned_devices
      @provisioned_devices ||= read_provisioned_profile_array('ProvisionedDevices')
    end

    def seed_id
      @seed_id ||= begin
        seed_ids = read_provisioned_profile_array('ApplicationIdentifierPrefix')
        if seed_ids.size == 0
          App.fail "Can't find an application seed ID in the provisioning profile `#{provisioning_profile}'"
        elsif seed_ids.size > 1
          App.warn "Found #{seed_ids.size} seed IDs in the provisioning profile. Set the `seed_id' project setting. Will use the last one: `#{seed_ids.last}'"
        end
        seed_ids.last
      end
    end

    def entitlements_data
      dict = entitlements
      if distribution_mode
        dict['application-identifier'] ||= seed_id + '.' + identifier
      else
        # Required for gdb.
        dict['get-task-allow'] = true if dict['get-task-allow'].nil?
      end
      Motion::PropertyList.to_s(dict)
    end

    def fonts
      @fonts ||= begin
        resources_dirs.flatten.inject([]) do |fonts, dir|
          if File.exist?(dir)
            Dir.chdir(dir) do
              fonts.concat(Dir.glob('*.{otf,ttf}'))
            end
          else
            fonts
          end
        end
      end
    end

    def gen_bridge_metadata(headers, bs_file)
      sdk_path = self.sdk(local_platform)
      includes = headers.map { |header| "-I'#{File.dirname(header)}'" }.uniq
      a = sdk_version.scan(/(\d+)\.(\d+)/)[0]
      sdk_version_headers = ((a[0].to_i * 10000) + (a[1].to_i * 100)).to_s
      extra_flags = OSX_VERSION >= 10.7 ? '--no-64-bit' : ''
      sh "RUBYOPT='' /usr/bin/gen_bridge_metadata --format complete #{extra_flags} --cflags \"-isysroot #{sdk_path} -miphoneos-version-min=#{sdk_version} -D__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__=#{sdk_version_headers} -I. #{includes.join(' ')}\" #{headers.map { |x| "\"#{x}\"" }.join(' ')} -o \"#{bs_file}\""
    end

    def define_global_env_txt
      rubymotion_env =
        if spec_mode
          'test'
        else
          development? ? 'development' : 'release'
        end
      "rb_define_global_const(\"RUBYMOTION_ENV\", @\"#{rubymotion_env}\");\nrb_define_global_const(\"RUBYMOTION_VERSION\", @\"#{Motion::Version}\");\n"
    end
  end
end; end
