require 'fourflusher'

PLATFORMS = { 'iphonesimulator' => 'iOS',
              'appletvsimulator' => 'tvOS',
              'watchsimulator' => 'watchOS' }

def build(sandbox, build_dir, target, configuration)
  deployment_target = target.platform_deployment_target
  target_label = target.cocoapods_target_label

  Pod::UI.puts 'Building framework for ios device'
  xcodebuild(sandbox, build_dir, target_label, 'iphoneos', deployment_target, %W(SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES), configuration)

  Pod::UI.puts 'Building framework for mac'
  xcodebuild(sandbox, build_dir, target_label, 'macosx', deployment_target, %W(-destination platform=macOS,arch=arm64 SKIP_INSTALL=NO SUPPORTS_MACCATALYST=YES BUILD_LIBRARY_FOR_DISTRIBUTION=YES), configuration)

  Pod::UI.puts 'Building framework for ios simulator'
  xcodebuild(sandbox, build_dir, target_label, 'iphonesimulator', deployment_target, %W(SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES), configuration)

  spec_names = target.specs.map { |spec| [spec.root.name, spec.root.module_name] }.uniq
  spec_names.each do |root_name, module_name|
    device_lib = "#{build_dir}/#{configuration}-iphoneos/#{root_name}/#{module_name}.framework"
    catalyst_lib = "#{build_dir}/#{configuration}-maccatalyst/#{root_name}/#{module_name}.framework"
    simulator_lib = "#{build_dir}/#{configuration}-iphonesimulator/#{root_name}/#{module_name}.framework"

    Pod::UI.puts 'Building xcframework'
    build_xcframework([device_lib, catalyst_lib, simulator_lib], build_dir, module_name)

    FileUtils.rm device_lib if File.file?(device_lib)
    FileUtils.rm catalyst_lib if File.file?(catalyst_lib)
    FileUtils.rm simulator_lib if File.file?(simulator_lib)
  end
end

def xcodebuild(sandbox, build_dir, target, sdk='macOS', deployment_target=nil, flags=nil, configuration)
  args = %W(-derivedDataPath #{build_dir} -project #{sandbox.project_path.realdirpath} -scheme #{target} -configuration #{configuration} -sdk #{sdk})
  args += flags unless flags.nil?  
  platform = PLATFORMS[sdk]
  args += Fourflusher::SimControl.new.destination(:oldest, platform, deployment_target) unless platform.nil?
  Pod::Executable.execute_command 'xcodebuild', args, true
end

def build_xcframework(frameworks, build_dir, module_name)
  output = "#{build_dir}/#{module_name}.xcframework"
  return if File.exist?(output) 

  args = %W(-create-xcframework -output #{output})

  frameworks.each do |framework|
    return unless File.exist?(framework) 
    args += %W(-framework #{framework})
  end

  Pod::Executable.execute_command 'xcodebuild', args, true
end

def enable_debug_information(project_path, configuration)
  project = Xcodeproj::Project.open(project_path)
  project.targets.each do |target|
    config = target.build_configurations.find { |config| config.name.eql? configuration }
    config.build_settings['DEBUG_INFORMATION_FORMAT'] = 'dwarf-with-dsym'
    config.build_settings['ONLY_ACTIVE_ARCH'] = 'NO'
  end
  project.save
end

def copy_dsym_files(dsym_destination, configuration)
  dsym_destination.rmtree if dsym_destination.directory?
  platforms = ['iphoneos', 'iphonesimulator']
  platforms.each do |platform|
    dsym = Pathname.glob("build/#{configuration}-#{platform}/**/*.dSYM")
    dsym.each do |dsym|
      destination = dsym_destination + platform
      FileUtils.mkdir_p destination
      FileUtils.cp_r dsym, destination, :remove_destination => true
    end
  end
end

Pod::HooksManager.register('cocoapods-rome', :post_install) do |installer_context, user_options|
  enable_dsym = user_options.fetch('dsym', true)
  configuration = user_options.fetch('configuration', 'Debug')

  flags = [] 
  
  # Setting SKIP_INSTALL=NO to access the built frameworks inside the archive created
  # instead of searching in Xcode’s default derived data folder
  flags << "SKIP_INSTALL=NO"

  # Use custom flags passed via user options, if any
  flags += user_options["flags"] if user_options["flags"]
  
  if user_options["pre_compile"]
    user_options["pre_compile"].call(installer_context)
  end

  sandbox_root = Pathname(installer_context.sandbox_root)
  sandbox = installer_context.sandbox

  enable_debug_information(sandbox.project_path, configuration) if enable_dsym

  build_dir = sandbox_root.parent + 'build'
  destination = sandbox_root.parent + '../../BinaryPods'

  Pod::UI.puts 'Building frameworks'

  build_dir.rmtree if build_dir.directory?
  targets = installer_context.umbrella_targets.select { |t| t.specs.any? }
  targets.each do |target|
    case target.platform_name
    when :ios then build(sandbox, build_dir, target, configuration)
    else raise "Unknown platform '#{target.platform_name}'" end
  end

  raise Pod::Informative, 'The build directory was not found in the expected location.' unless build_dir.directory?

  # Make sure the device target overwrites anything in the simulator build, otherwise iTunesConnect
  # can get upset about Info.plist containing references to the simulator SDK
  build_type = "xcframework"
  frameworks = Pathname.glob("build/*/*/*.#{build_type}").reject { |f| f.to_s =~ /Pods[^.]+\.#{build_type}/ }
  frameworks += Pathname.glob("build/*.#{build_type}").reject { |f| f.to_s =~ /Pods[^.]+\.#{build_type}/ }

  resources = []

  Pod::UI.puts "Built #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)}"

  destination.rmtree if destination.directory?

  installer_context.umbrella_targets.each do |umbrella|
    umbrella.specs.each do |spec|
      consumer = spec.consumer(umbrella.platform_name)
      file_accessor = Pod::Sandbox::FileAccessor.new(sandbox.pod_dir(spec.root.name), consumer)
      frameworks += file_accessor.vendored_libraries
      frameworks += file_accessor.vendored_frameworks
      resources += file_accessor.resources
    end
  end
  frameworks.uniq!
  resources.uniq!

  Pod::UI.puts "Copying #{frameworks.count} #{'frameworks'.pluralize(frameworks.count)} " \
    "to `#{destination.relative_path_from Pathname.pwd}`"

  FileUtils.mkdir_p destination
  (frameworks + resources).each do |file|
    FileUtils.cp_r file, destination, :remove_destination => true
  end

  copy_dsym_files(sandbox_root.parent + 'dSYM', configuration) if enable_dsym

  build_dir.rmtree if build_dir.directory?

  if user_options["post_compile"]
    user_options["post_compile"].call(installer_context)
  end
end
