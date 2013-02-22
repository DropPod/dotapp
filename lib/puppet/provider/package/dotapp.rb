require 'open-uri'
require 'digest/md5'
require 'net/https'

# Note: This is terrible, but it helps match browser behavior in the real world.
def OpenURI.redirectable?(a, b)
  a.scheme =~ /^https?$/i && b.scheme =~ /^https?$/i
end

require 'puppet/provider/package'

Puppet::Type.type(:package).provide(:dotapp, :parent => Puppet::Provider::Package) do
  desc "Package management which copies application bundles to a target."

  confine :operatingsystem => :darwin

  has_feature :installable
  has_feature :upgradeable

  commands :xattr   => '/usr/bin/xattr'
  commands :hdiutil => '/usr/bin/hdiutil'
  commands :ditto   => '/usr/bin/ditto'
  commands :file    => '/usr/bin/file'
  commands :unzip   => '/usr/bin/unzip'
  commands :tar     => '/usr/bin/tar'

  # Collects metadata from all applications installed in /Applications.
  def self.metadata
    @metadata ||= Dir['/Applications/*.app'].inject({}) do |hash, app|
      xattrs = xattr(app).split("\n")
      xattrs = xattrs.map { |name| [ name, xattr('-p', name, app).chomp ] }
      hash[app[/[^\/]+.app/]] = Hash[xattrs]
      hash
    end
  end

  # Coerces metadata into a set of normalized resource description hashes.
  def self.instance_hashes
    metadata.map do |app, data|
      parameters = {
        :name     => app,
        :ensure   => data['dev.drop_pod.metadata:checksum'] ||
                     :installed,
        :provider => :dotapp,
        :source   => data['dev.drop_pod.metadata:source'],
      }.delete_if { |_,v| v.nil? }

      block_given? ? yield(parameters) : parameters
    end
  end

  # Coerces the resource description hashes into instances of `self`.
  def self.instances
    instance_hashes { |parameters| self.new(parameters) }
  end

  # Locates the named instance's resource description hash.
  def query
    self.class.instance_hashes.find { |x| x[:name] == @resource[:name] }
  end

  # Looks up the latest available version of the package.
  # This is done by comparing checksums (when available) and modification dates.
  def latest
    unless source = @resource[:source]
      self.fail "Mac OS X packages must specify a package source"
    end

    # If we have an HTTP(S) URL, we should try a HEAD request.  In the best
    # case, we get our information without having to download the package.
    if (uri = URI.parse(source)).is_a? URI::HTTP
      begin
        request = proc do |uri|
          Net::HTTP.new(uri.host, uri.port).start do |h|
            h.request_head(uri.request_uri)
          end
        end

        head = request[uri]
        while head.is_a?(Net::HTTPRedirection)
          head = request[URI.parse(head['location'])]
        end

        latest = head['etag'][1..-2] rescue
                 Time.httpdate(head['last-modified']).to_i.to_s rescue
                 nil
        return latest if latest
      rescue
      end
    end

    # If our HEAD request failed to return fruitful results, we can always just
    # stage the file for later.
    Puppet.debug "Fetching from source '%s'" % source
    @package = open(source, 'rb')

    return @package.meta['etag'][1..-2] rescue
           Time.httpdate(@package.meta['last-modified']).to_i.to_s rescue
           Digest::MD5.file(@package.path).hexdigest rescue
           nil
  end

  def install
    unless source = @resource[:source]
      self.fail "Mac OS X packages must specify a package source"
    end

    Puppet.debug "Copying data from source '%s'" % source
    package = @package || open(source, 'rb')
    metadata = package.respond_to?(:meta) ? {}.merge(package.meta) : {}

    # Normalize metadata
    metadata['checksum'] ||= metadata['etag'][1..-2] rescue nil
    metadata['checksum'] ||= Time.httpdate(metadata['last-modified']).to_i rescue nil
    metadata['checksum'] ||= Digest::MD5.file(package.path).hexdigest rescue nil

    tmpdir = Dir.mktmpdir
    begin
      # Try to mount the file as a disk image
      hdiutil 'attach', '-readwrite', '-shadow', '-nobrowse', '-mountpoint', tmpdir, package.path
    rescue => e
      if file(package.path) =~ /\bZip archive data\b/
        unzip package.path, '-d', tmpdir
      elsif file(package.path) =~ /\b(gzip|bzip2) compressed data\b/
        tar '-xzC', tmpdir, '-f', package.path
      else
        self.fail "Could not mount the disk image"
      end
    end

    # Abort if the named application cannot be found in the package.
    app = File.join(tmpdir, name)
    unless File.directory?(app)
      self.fail "Source package does not include the application #{name}"
    end

    # Copy the application directory wholesale, straight into /Applications.
    ditto app, "/Applications/#{name}"

    # Set appropriate metadata fields on the application directory, so that we
    # can track it appropriately.
    app = "/Applications/#{name}"
    xattr '-w', 'dev.drop_pod.metadata:name', name, app
    xattr '-w', 'dev.drop_pod.metadata:source', source, app
    xattr '-w', 'dev.drop_pod.metadata:checksum', metadata['checksum'], app if metadata['checksum']
  end
  alias :update :install
end
