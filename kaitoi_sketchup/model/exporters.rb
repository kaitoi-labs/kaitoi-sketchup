require 'fileutils'
require 'tmpdir'
require 'digest'

module Kaitoio
  module Model
    module Exporters
      module_function

      def save_active_model_skp(model, dest_path: nil)
        raise ArgumentError, 'Model is nil' unless model
        dest_path ||= File.join(Dir.tmpdir, "kaitoi_model_#{Time.now.to_i}.skp")
        ok = model.save(dest_path)
        raise Kaitoio::Error.new("Failed to save .skp: #{dest_path}") unless ok
        dest_path
      end

      def export_scene_pngs(model, views: nil, output_dir: nil, width: 1280, height: 720, antialias: true, transparent: false)
        output_dir ||= File.join(Dir.tmpdir, "kaitoi_previews_#{Time.now.to_i}")
        FileUtils.mkdir_p(output_dir)
        results = []
        pages = views || (model.respond_to?(:pages) ? model.pages.to_a : [])

        if !pages.empty?
          original_page = model.pages.selected_page
          begin
            pages.each do |page|
              model.pages.selected_page = page
              view = model.active_view
              file = File.join(output_dir, "scene_#{safe_name(page.name)}.png")
              write_png(view, file, width: width, height: height, antialias: antialias, transparent: transparent)
              results << { 'scene' => page.name, 'path' => file }
            end
          ensure
            model.pages.selected_page = original_page if original_page
          end
        else
          file = File.join(output_dir, "scene_main.png")
          write_png(model.active_view, file, width: width, height: height, antialias: antialias, transparent: transparent)
          results << { 'scene' => 'main', 'path' => file }
        end
        results
      end

      def write_png(view, path, width: 1280, height: 720, antialias: true, transparent: false)
        view.write_image(
          filename:    path,
          width:       width,
          height:      height,
          antialias:   antialias,
          transparent: transparent
        )
        path
      end

      def safe_name(s)
        s.to_s.gsub(/[^A-Za-z0-9._-]+/, '_')
      end
    end
  end
end
