ssv_to_rds <- function(inputFile, missionNumber, gliderName, mapGen = FALSE, updateProgress = NULL) {

library(tidyverse)
library(lubridate)
  library(seacarb)
  library(osgUtils)
  
  #https://rdrr.io/github/AustralianAntarcticDivision/ZooScatR/src/R/soundvelocity.R
  c_Coppens1981 <- function(D,S,T){
    t <- T/10
    D = D/1000
    c0 <- 1449.05 + 45.7*t - 5.21*(t^2)  + 0.23*(t^3)  + (1.333 - 0.126*t + 0.009*(t^2)) * (S - 35)
    c <- c0 + (16.23 + 0.253*t)*D + (0.213-0.1*t)*(D^2)  + (0.016 + 0.0002*(S-35))*(S- 35)*t*D
    return(c)
  }
  
  #https://rdrr.io/cran/wql/man/ec2pss.html
  ec2pss <-
    function (ec, t, p = 0) {
      # Define conductivity ratio
      R <- ec/42.914
      
      # Estimate temperature correction (valid for -2 < t < 35)
      c <- c(0.6766097, 0.0200564, 0.0001104259, -6.9698e-07, 1.0031e-09)
      rt <- c[1] + c[2] * t + c[3] * t^2 + c[4] * t^3 + c[5] * t^4
      
      # Estimate pressure correction (validity range varies with t and S)
      d <- c(0.03426, 0.0004464, 0.4215, -0.003107)
      e <- c(2.07e-05, -6.37e-10, 3.989e-15)
      Rp <- 1 + p * (e[1] + e[2] * p + e[3] * p^2)/(1 + d[1] * t + 
                                                      d[2] * t^2 + (d[3] + d[4] * t) * R)
      
      # Estimate salinity (valid for 2 < S < 42 and -2 < t < 35).       
      Rt <- R/(Rp * rt)
      a <- c(0.008, -0.1692, 25.3851, 14.0941, -7.0261, 2.7081)
      b <- c(5e-04, -0.0056, -0.0066, -0.0375, 0.0636, -0.0144)
      ft <- (t - 15)/(1 + 0.0162 * (t - 15))
      S <- a[1] + a[2] * Rt^0.5 + a[3] * Rt + a[4] * Rt^1.5 + a[5] * 
        Rt^2 + a[6] * Rt^2.5 + ft * (b[1] + b[2] * Rt^0.5 + b[3] * 
                                       Rt + b[4] * Rt^1.5 + b[5] * Rt^2 + b[6] * Rt^2.5)
      
      # Estimate salinity correction for S < 2
      x <- 400 * Rt
      y <- 100 * Rt
      ifelse(S >= 2, S, S - a[1]/(1 + 1.5 * x + x^2) - b[1] * ft/(1 + 
                                                                    y^0.5 + y + y^1.5))
    }
  
  identify_casts <- function(data, depth_col, surface_threshold = 0.1) {
    # Initialize vectors to store cast information
    casts <- character(nrow(data))
    
    # Find the index where depth data becomes available
    first_depth_index <- which(!is.na(data[[depth_col]]))[1]
    
    # Initialize casts for missing depth rows as "Unknown"
    casts[1:(first_depth_index - 1)] <- "Unknown"
    
    # Initialize the first cast based on the second data point with depth
    if (!is.na(data[[depth_col]][first_depth_index + 1])) {
      if (data[[depth_col]][first_depth_index + 1] > data[[depth_col]][first_depth_index]) {
        casts[first_depth_index] <- "Downcast"
      } else {
        casts[first_depth_index] <- "Upcast"
      }
    }
    
    # Loop through the data to identify casts
    for (i in (first_depth_index + 1):nrow(data)) {
      if (!is.na(data[[depth_col]][i]) && !is.na(data[[depth_col]][i - 1])) {
        if (data[[depth_col]][i] > data[[depth_col]][i - 1]) {
          casts[i] <- "Downcast"
        } else if (data[[depth_col]][i] < data[[depth_col]][i - 1]) {
          casts[i] <- "Upcast"
        } else {
          casts[i] <- "Surface"
        }
      }
    }
    
    # Assign "Surface" to points with depth near zero or below the surface threshold
    casts[data[[depth_col]] < surface_threshold] <- "Surface"
    
    # Create a new column in the dataframe to store the cast information
    data$cast <- casts
    
    return(data)
  }
  
missionNum <- sub(".ssv", "", missionNumber)

head <- read.csv(inputFile,
                 sep="", #whitespace as delimiter
                 nrows=1)

#screen for required variables
requiredVars <- c("m_present_time", 
                  "m_gps_lat",
                  "m_gps_lon", 
                  "sci_water_cond",
                  "sci_water_temp", 
                  "sci_water_pressure")

missing_columns <- setdiff(requiredVars, colnames(head))

#stop function if missing anything and report
if (length(missing_columns) > 0) {
  stop(paste("Missing column(s):", paste(missing_columns, collapse = ", ")))
} else {
  if (is.function(updateProgress)) {
    updateProgress(detail = "All required columns are present")
  }
  message("All required columns are present")
}

raw <- read.csv(inputFile,
                sep="", #whitespace as delimiter
                skip=2,
                header = FALSE)

colnames(raw) <- colnames(head)

flight <- raw %>%
  select(starts_with(c("m_", "c_", "x_"))) %>%
  mutate(m_present_time = as_datetime(floor(seconds(m_present_time)))) %>% #convert to POSIXct
  filter(., rowSums(is.na(.)) != ncol(.)-1) #remove lines that are all NA except time
  
#for very old data, sci_m_present_time may not exist
if("sci_m_present_time" %in% colnames(raw)){
science <- raw %>%
  select(starts_with("sci_")) %>%
  mutate(sci_m_present_time = as_datetime(floor(seconds(sci_m_present_time)))) %>%
  filter(., rowSums(is.na(.)) != ncol(.)-1) %>% #remove lines that are all NA except time
  mutate(m_present_time = sci_m_present_time) #convert to POSIXct
} else {
  science <- raw %>%
    select(c(m_present_time, starts_with("sci_"))) %>%
    mutate(m_present_time = as_datetime(floor(seconds(m_present_time)))) %>% #convert to POSIXct
    filter(., rowSums(is.na(.)) != ncol(.)-1) #remove lines that are all NA except time
}

full <- flight %>%
  full_join(science)
  
#lots of GPS massaging
gps <- full %>%
  select(m_present_time, m_gps_lat, m_gps_lon) %>%
  filter(!is.na(m_gps_lat)) %>% #clean up input for conversion
  mutate(latt = format(m_gps_lat, nsmall = 4),
         longg = format(m_gps_lon, nsmall = 4)) %>% #coerce to character keeping zeroes out to 4 decimals
  mutate(lat = gliderGPS_to_dd(latt),
         long = gliderGPS_to_dd(longg)) %>%
  # mutate(lat = gliderGPS_to_dd(m_gps_lat),
  #        long = gliderGPS_to_dd(m_gps_lon)) %>%
  select(m_present_time, lat, long) %>%
  filter(lat >= -90 & lat <= 90) %>% #remove illegal values
  filter(long >= -180 & long <= 180)

if (is.function(updateProgress)) {
  updateProgress(detail = "GPS interpolation")
}
message("GPS interpolation")

library(zoo)

full.time <- with(gps,seq(m_present_time[1],tail(m_present_time,1),by=1)) #grab full list of timestamps
gps.zoo <- zoo(gps[2:3], gps$m_present_time) #convert to zoo
result <- na.approx(gps.zoo, xout = full.time) #interpolate

igps <- fortify.zoo(result) %>% #extract out as DF
  rename(i_lat = lat) %>%
  rename(i_lon = long) %>%
  rename(m_present_time = Index) %>%
  mutate(m_present_time = as_datetime(m_present_time))

#force both time sets to match (i.e., round to 1sec)
igps$m_present_time <- as_datetime(floor(seconds(igps$m_present_time)))
#raw$m_present_time <- as_datetime(floor(seconds(raw$m_present_time)))

if (is.function(updateProgress)) {
  updateProgress(detail = "Depth interpolation")
}
message("Depth interpolation")

gliderdfInt <- full %>%
  left_join(igps) %>%
  mutate(osg_depth = p2d(sci_water_pressure*10, lat=i_lat)) #calculate CTD depth with interpolated latitude
  
#interpolate across depth
idepth <- depthInt(gliderdfInt, CTD = TRUE)

#join the interpolations back in
gliderdfNext <- full %>%
  left_join(idepth) %>%
  left_join(igps) %>%
  arrange(m_present_time)

if (is.function(updateProgress)) {
  updateProgress(detail = "Vehicle state identification")
}
message("Vehicle state identification")

#glider state algorithms
inDF <- gliderdfNext %>%
  select(m_present_time, osg_i_depth) %>%
  filter(!is.na(osg_i_depth)) %>%
  arrange(m_present_time)

#setup bandpass filter
bf <- signal::butter(3, .05) 

#filter both directions using above
inDF$filt_depth <- signal::filtfilt(filt = bf, x = inDF$osg_i_depth)

#label using filtered depth
gliderStateFirst <- identify_casts(inDF, "filt_depth", surface_threshold = 1)

surfDF <- gliderStateFirst %>%
  filter(cast != "Downcast" & cast != "Upcast") %>%
  select(m_present_time, cast)

castDF <- gliderStateFirst %>%
  filter(cast == "Downcast" | cast == "Upcast") %>% #strip out surface/unknown for yo ID
  arrange(m_present_time) %>% 
  add_yo_id() %>%
  select(m_present_time, cast, yo_id)

gliderState <- surfDF %>%
  bind_rows(castDF) 

if (is.function(updateProgress)) {
  updateProgress(detail = "Data assembly")
}
message("Data assembly")

gliderdf <- gliderdfNext %>%
  left_join(gliderState) %>%
  arrange(m_present_time) %>% #ensure chronological order
  #compute some derived variables with CTD data
  mutate(osg_salinity = ec2pss(sci_water_cond*10, sci_water_temp, sci_water_pressure*10)) %>%
  mutate(osg_theta = theta(osg_salinity, sci_water_temp, sci_water_pressure)) %>%
  mutate(osg_rho = rho(osg_salinity, osg_theta, sci_water_pressure)) %>%
  mutate(osg_depth = p2d(sci_water_pressure*10, lat=i_lat)) %>%
  mutate(osg_soundvel1 = c_Coppens1981(osg_depth,
                                       osg_salinity,
                                       sci_water_temp))

if (is.function(updateProgress)) {
  updateProgress(detail = "Saving everything")
}
message("Saving everything")

save(gliderdf, gliderName, file = paste0("./Data/",missionNum,"_",gliderName,".RData"))

if (is.function(updateProgress)) {
  updateProgress(detail = "Wrapping up")
}

message("Generating report")
quarto_render("mission_report.qmd", 
              output_file = paste0(missionNum, "_", gliderName, "_overview.html"), 
              output_format = "html",
              execute_params = list(mission = paste0(missionNum, "_", gliderName)))
#rename because relative path not allowed in quarto render call
file.rename(from = paste0(missionNum, "_", gliderName, "_overview.html"),
            to = paste0("./www/", missionNum, "_", gliderName, "_overview.html"))

if(isTRUE(mapGen)){
  message("Generating map")
  write.csv(gps, file = paste0("./KML/",missionNum,"_",gliderName,".csv"))
}

}
