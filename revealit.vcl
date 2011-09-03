# Reveal ITs Varnish configuration.
#
# This is primarily minded on Drupal sites.
# Much of the inspiration commes from Nate Haug’s blog post:
# http://www.lullabot.com/articles/varnish-multiple-web-servers-drupal

backend nginx {
     .host = "127.0.0.1";
     .port = "8080";
}

sub vcl_recv {
  # Default backend is nginx, plain and simple.
  set req.backend = nginx;

  # Allow the backend to serve up stale content if it is responding slowly.
  set req.grace = 6h;

  # Use anonymous, cached pages if all backends are down.
  if (!req.backend.healthy) {
    unset req.http.Cookie;
  }

  # Set the X-Forwarded-For header so the backend can see the original
  # IP address.
  remove req.http.X-Forwarded-For;
  set req.http.X-Forwarded-For = client.ip;

  # Do not cache these paths.
  if (req.url ~ "^/status\.php$" ||
      req.url ~ "^/update\.php" ||
      req.url ~ "^/install\.php" ||
      req.url ~ "^/piwik\.php" ||
      req.url ~ "^/admin/build/features" ) {
      return (pass);
  }

  # Pipe these paths directly to Apache for streaming.
  if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }

  # Deal with GET and HEAD  requests only, everything else gets through
  if (req.request != "GET" &&
      req.request != "HEAD") {
    return (pass);
  }

  # Always cache the following file types for all users.
  if (req.url ~ "(?i)\.(png|gif|jpeg|jpg|ico|swf|css|js|html|htm)(\?[a-z0-9]+)?$") {
    unset req.http.Cookie;
  }

  # Handle compression correctly. Different browsers send different
  # "Accept-Encoding" headers, even though they mostly all support the same
  # compression mechanisms. By consolidating these compression headers into
  # a consistent format, we can reduce the size of the cache and get more hits.
  # @see: http://varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      # If the browser supports it, we'll use gzip.
      set req.http.Accept-Encoding = "gzip";
    }
    else if (req.http.Accept-Encoding ~ "deflate" && req.http.user-agent !~ "MSIE") {
      # Next, try deflate if it is supported.
      set req.http.Accept-Encoding = "deflate";
    }
    else {
      # Unknown algorithm. Remove it and send unencoded.
      unset req.http.Accept-Encoding;
    }
  }

  # Remove all cookies that Drupal doesn't need to know about. ANY remaining
  # cookie will cause the request to pass-through to Apache. For the most part
  # we always set the NO_CACHE cookie after any POST request, disabling the
  # Varnish cache temporarily. The session cookie allows all authenticated users
  # to pass through as long as they're logged in.
  if (req.http.Cookie) {
    # Prepend semicolon for the regexes below to work.
    set req.http.Cookie = ";" + req.http.Cookie;

    # Remove spaces after the semicolons separating cookies.
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");

    # Put space folloing semicolon back for whitelisted cookies.
    set req.http.Cookie = regsuball(req.http.Cookie, ";(SESS[0-9a-f]+|NO_CACHE|csrftoken|sessionid|[a-z_]+session|sam_currency_country)=", "; \1=");

    # Remove cookies not preceeded by a space.
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");

    # Strip semicolons and spaces from the start and the end of the cookie string.
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      # If there are no remaining cookies, remove the cookie header. If there
      # aren't any cookie headers, Varnish's default behavior will be to cache
      # the page.
      unset req.http.Cookie;
    }
    else {
      # If there are any cookies left (a session or NO_CACHE cookie), do not
      # cache the page. Pass it on to Apache directly.
      return (pass);
    }
  }
}

# Code determining what to do when serving items from the backend servers.
sub vcl_fetch {
  # Don't allow static files to set cookies.
  if (req.url ~ "(?i)\.(png|gif|jpeg|jpg|ico|swf|css|js|html|htm)(\?[a-z0-9]+)?$") {
    # beresp == Back-end response from the web server.
    unset beresp.http.set-cookie;
  }

  # Allow items to be stale if needed.
  set beresp.grace = 6h;
}

# When cached data is delivered to the client, set a bit of cache info.
sub vcl_deliver {
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
  # Retry up to four times if the web site is temporarily unavailable.
  if (obj.status == 503 && req.restarts < 5) {
    set obj.http.X-Restarts = req.restarts;
    return(restart);
  }
}

sub vcl_hit {
  # Allow users force refresh
  if (!obj.ttl > 0s) {
    return(pass);
  }
}

