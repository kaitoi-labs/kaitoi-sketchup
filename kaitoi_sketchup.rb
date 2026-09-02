require 'sketchup.rb'
require 'extensions.rb'

# Version and name only -- cheap, and keeps one source of truth for what
# Extension Manager shows.
require_relative 'kaitoi_sketchup/version'

# Registration file. SketchUp loads .rb files sitting directly in Plugins/,
# and this one only registers the extension -- the real code is loaded by
# kaitoi_sketchup/loader.rb when SketchUp activates it.
#
# Registering with SketchupExtension is what makes the plugin appear in
# Window > Extension Manager, where it can be disabled or uninstalled, and it
# defers loading the rest until the extension is actually enabled.
module Kaitoio
  unless defined?(EXTENSION)
    EXTENSION = SketchupExtension.new(
      PLUGIN_NAME,
      File.join(File.dirname(__FILE__), 'kaitoi_sketchup', 'loader')
    )
    EXTENSION.description = 'Connects the active model to Kaitoi Studio: ' \
                            'capture the viewport, run it through Kaitoi nodes, ' \
                            'and bring the result back.'
    EXTENSION.version   = VERSION
    EXTENSION.creator   = 'Kaitoi Labs'
    EXTENSION.copyright = "\u00A9 #{Time.now.year} Kaitoi Labs"

    Sketchup.register_extension(EXTENSION, true)
  end
end
