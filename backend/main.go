package main

import (
	"fmt"
	"net/http"
	"os"
	"github.com/gin-gonic/gin"
)

type Device struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Lat         float64 `json:"lat"`
	Lng         float64 `json:"lng"`
	Status      string  `json:"status"`
	Battery     int     `json:"battery"`
	Temperature float64 `json:"temperature"`
}

var devices = []Device{
	{ID: "d1", Name: "Sensor-A01", Lat: 39.9042, Lng: 116.4074, Status: "online", Battery: 85, Temperature: 24.5},
	{ID: "d2", Name: "Sensor-B02", Lat: 39.9142, Lng: 116.3974, Status: "alert", Battery: 12, Temperature: 38.2},
}

func main() {
	r := gin.Default()
	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "IoT Geofence Monitor"})
	})
	r.GET("/api/devices", func(c *gin.Context) {
		c.JSON(http.StatusOK, devices)
	})
	r.POST("/api/devices", func(c *gin.Context) {
		var d Device
		if err := c.BindJSON(&d); err != nil { c.JSON(400, err); return }
		devices = append(devices, d)
		c.JSON(http.StatusCreated, d)
	})
	addr := ":" + os.Getenv("PORT")
	if os.Getenv("PORT") == "" {
		addr = ":8080"
	}
	fmt.Println("Server on " + addr)
	if err := r.Run(addr); err != nil {
		fmt.Fprintln(os.Stderr, "server failed:", err)
		os.Exit(1)
	}
}
