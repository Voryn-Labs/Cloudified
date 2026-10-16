// Boost Software License - Version 1.0 - August 17th, 2003
// See licenses/LICENSE-TDLib.txt

#ifndef TDJSON_EXPORT_H
#define TDJSON_EXPORT_H

#ifdef TDJSON_STATIC_DEFINE
#  define TDJSON_EXPORT
#  define TDJSON_NO_EXPORT
#else
#  ifndef TDJSON_EXPORT
#    ifdef tdjson_EXPORTS
#      define TDJSON_EXPORT __attribute__((visibility("default")))
#    else
#      define TDJSON_EXPORT __attribute__((visibility("default")))
#    endif
#  endif

#  ifndef TDJSON_NO_EXPORT
#    define TDJSON_NO_EXPORT __attribute__((visibility("hidden")))
#  endif
#endif

#endif /* TDJSON_EXPORT_H */
