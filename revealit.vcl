# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.
# 
# Default backend definition.  Set this to point to your content
# server.
 
backend default {
     .host = "127.0.0.1";
     .port = "8080";
}
 
sub vcl_recv {
  # Allow a grace period for offering "stale" data in case backend lags
  set req.grace = 5m;

  remove req.http.X-Forwarded-For;
  set req.http.X-Forwarded-For = client.ip;

  # Deal with GET and HEAD  requests only, everything else gets through
  if (req.request != "GET" &&
      req.request != "HEAD") {
    return (pass);
  }

  # Normalise Accept-Encoding headers.
  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg)$") {
      # No point in compressing these
      remove req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate") {
      set req.http.Accept-Encoding = "deflate";
    } else {
      # unkown algorithm
      remove req.http.Accept-Encoding;
    }
  }
  if (req.url ~ "\.(css|jpg|gif|jpeg|png|html|js|ico)") {
    unset req.http.cookie;
    set req.url = regsub(req.url, "\?.*$", "");
  }

  // js
  if (req.url ~ "\.js$") {
    unset req.http.cookie;
    return(lookup);
  }
  // images
  if (req.url ~ "\.(gif|jpg|jpeg|bmp|png|tiff|tif|ico|img|tga|wmf)$") {
    unset req.http.cookie;
    return(lookup);
  }

  // Remove has_js and Google Analytics __* cookies.
  set req.http.Cookie = regsuball(req.http.Cookie, "(^|;\s*)(__[a-z]+|has_js)=[^;]*", "");

  // Remove a ";" prefix, if present.
  set req.http.Cookie = regsub(req.http.Cookie, "^;\s*", "");

  // Remove empty cookies.
  if (req.http.Cookie ~ "^\s*$") {
    unset req.http.Cookie;
  }

  if (req.http.Cookie ~ "(VARNISH|DRUPAL_UID|NO_CACHE)") {
    return(pass);
  }
}

sub vcl_fetch {  
  # These status codes should always pass through and never cache.
  if (beresp.status == 404 || beresp.status == 503 || beresp.status == 500) {
    set beresp.http.X-Cacheable = "NO: beresp.status";
    set beresp.http.X-Cacheable-status = beresp.status;
    return(pass);
  }

  # Grace to allow varnish to serve content if backend is lagged
  set beresp.grace = 5m;

  # Static files are cached for an hour
  if (req.url ~ "\.(gif|jpg|jpeg|bmp|png|tiff|tif|ico|img|tga|wmf|js|css|bz2|tgz|gz|mp3|ogg|swf)") {
    set beresp.ttl = 60m;
    remove req.http.Accept-Encoding;
    unset req.http.set-cookie;
  }

  # marker for vcl_deliver to reset Age:
  set beresp.http.magicmarker = "1";

  return(deliver);
}

sub vcl_deliver {
  # Remove the magic marker
  if (resp.http.magicmarker) {
    unset resp.http.magicmarker;

    # By definition we have a fresh object
    set resp.http.age = "0";
  }

  # Add cache hit data
  if (obj.hits > 0) {
    # If hit add hit count
    set resp.http.X-Cache = "HIT";
    set resp.http.X-Cache-Hits = obj.hits;
  } else {
    set resp.http.X-Cache = "MISS";
  }
}

sub vcl_error {
  if (obj.status == 503 && req.restarts < 5) {
    set obj.http.X-Restarts = req.restarts;
    restart;
  }
}

sub vcl_hit {
  # Allow users force refresh
  if (!obj.cacheable) {
    return(pass);
  }
}

