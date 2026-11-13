# CocoaPods skips the mpv sources outside the plugin's macos/ios pod root.
def include_media_kit_mpv(target, plugin_path)
  return unless target.name == 'media_kit_video'

  mpv = Pathname.new(plugin_path).join('common/mpv').relative_path_from(target.project.path.dirname)
  source = target.project.main_group.new_file(mpv.join('media_kit_mpv.c').to_s)
  target.source_build_phase.add_file_reference(source)
  target.build_configurations.each do |config|
    config.build_settings['OTHER_SWIFT_FLAGS'] = "$(inherited) -I \"$(PROJECT_DIR)/#{mpv}/include\" -Xfrontend -import-module -Xfrontend Mpv"
  end
end
