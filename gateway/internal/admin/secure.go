package admin

import (
	"net/http"

	"github.com/nebu/nebu/internal/middleware"
)

func isRequestSecure(r *http.Request) bool {
	return middleware.IsRequestSecure(r)
}
