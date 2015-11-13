require 'pathname'

module AcpcBackend
  def self.resolve_path(path, root = __FILE__)
    path = Pathname.new(path)
    if path.exist?
      path.realpath
    else
      File.expand_path(path, root)
    end
  end
end
