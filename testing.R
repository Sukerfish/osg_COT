library(tidyverse)
library(ggplot2)
library(shiny)
library(patchwork)
library(cowplot)
library(plotly)
library(oce)
library(ocedata)
library(PlotSvalbard) #devtools::install_github("MikkoVihtakari/PlotSvalbard", upgrade = "never")
library(gsw)
library(seacarb)

#library(Cairo)   # For nicer ggplot2 output when deployed on Linux

#library(lubridate)

#### yo identification #######


# source: https://github.com/dankelley/oceanglider/blob/7d09741e73ea4c369449df73e9987518c8ddee0a/R/seaexplorer.R
#' The numerical values for type `slocum` are as follows. (These
#' are(defined as `m_depth_state` in the `slocum` documentation;
#' see pages 1-24 of reference 1.)
#' \tabular{lll}{
#' **Name**   \tab **Value** \tab **Description**\cr
#' `ignore`   \tab        99 \tab              - \cr
#' `hover`    \tab         3 \tab              - \cr
#' `climbing` \tab         2 \tab              - \cr
#' `diving`   \tab         1 \tab              - \cr
#' `surface`  \tab         0 \tab              - \cr
#' `none`     \tab        -1 \tab              - \cr
#'}



# missionNumber <- "output"
# 
# head <- read.csv(paste0(missionNumber,".ssv"),
#                  sep="", #whitespace as delimiter
#                  nrows=1,
#                  skip=500)
# 
# raw <- read.csv(paste0(missionNumber,".ssv"),
#                 sep="", #whitespace as delimiter
#                 skip=503,
#                 header = FALSE)
# 
# colnames(raw) <- colnames(head)
# 
# raw <- raw %>%
#   mutate(m_present_time = as_datetime(m_present_time)) #convert to POSIXct
# 
# raw$m_present_time <- as_datetime(floor(seconds(raw$m_present_time)))

# fileList <- list.files(path = ".",
#            pattern = "*.RData")

glider <- read_rds("M118.rds")
# glider$m_present_time <- as_datetime(floor(seconds(glider$m_present_time)))
# 
# glider <- glider %>%
#   left_join(raw)

#https://rdrr.io/github/AustralianAntarcticDivision/ZooScatR/src/R/soundvelocity.R
c_Coppens1981 <- function(D,S,T){
  t <- T/10
  D = D/1000
  c0 <- 1449.05 + 45.7*t - 5.21*(t^2)  + 0.23*(t^3)  + (1.333 - 0.126*t + 0.009*(t^2)) * (S - 35)
  c <- c0 + (16.23 + 0.253*t)*D + (0.213-0.1*t)*(D^2)  + (0.016 + 0.0002*(S-35))*(S- 35)*t*D
  return(c)
}

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



closest<-function(xv,sv){
  xv[which(abs(xv-sv)==min(abs(xv-sv)))] }




#pull out science variables
scivars <- glider %>%
  select(starts_with("sci")) %>%
  colnames()

#pull out flight variables
flightvars <- glider %>%
  select(!starts_with("sci")) %>%
  colnames()

input <- glider %>%
  select(c(m_roll, m_pitch)) %>%
  colnames()

chunk <- glider %>%
  filter(m_present_time >= "2022-8-15" & m_present_time < "2022-8-23") %>%
  mutate(status = if_else(m_avg_depth_rate > 0, "dive", "climb")) %>%
  fill(status) %>%
  #filter(status == "dive") %>%
  mutate(osg_salinity = ec2pss(sci_water_cond*10, sci_water_temp, sci_water_pressure*10)) %>%
  mutate(soundvel1 = c_Coppens1981(m_depth,
                                   osg_salinity,
                                   sci_water_temp))
  #mutate(conTemp = gsw_CT_from_t(sci_rbrctd_salinity_00, sci_rbrctd_temperature_00, sci_rbrctd_pressure_00)) %>%
  #mutate(soundvel2 = gsw_sound_speed(sci_rbrctd_salinity_00, conTemp, sci_rbrctd_pressure_00))
  
# pings <- chunk %>%
#   filter(!is.na(m_water_depth)) %>%
#   mutate(pingTime = 2*sci_rbrctd_depth_00*1540) #D = 1/2*v*t

chunkSummary <- chunk %>%
  select(all_of(input)) %>%
  summarise(across(everything(), list(stdev = ~ sd(.x, na.rm = TRUE), mean = ~ mean(.x, na.rm = TRUE))))
            
zunk <- chunk %>%
  select(all_of(input)) %>%
  mutate(across(m_roll, zscore = ((avg - LTmean)/stdev)))
  
#glider$m_present_time <- as_datetime(floor(seconds(glider$m_present_time)))
yunk <- glider %>%
  select(!c(status))

#ballast pump delta method ... and max battpos for surface
qunk <- glider %>%
  select(m_present_time, c_ballast_pumped, c_battpos) %>%
  filter(!is.nan(c_ballast_pumped)) %>%
  filter(!is.nan(c_battpos)) %>%
  mutate(batt_max = ifelse(c_battpos == max(c_battpos, na.rm = TRUE), 1, 0)) %>%
  mutate(pump_delta = c_ballast_pumped - lead(c_ballast_pumped)) %>%
  mutate(batt_delta = c_battpos - lead(c_battpos)) %>%
  #mutate(pump_max = ifelse(c_ballast_pumped == max(c_ballast_pumped, na.rm = TRUE), 1, 0)) %>%
  mutate(status = ifelse(batt_delta == 0 & batt_max == 1, "surface",
                         ifelse(pump_delta >= 100, "dive", 
                                ifelse(pump_delta <= -100, "climb", NA)))) %>%
  #mutate(status = ifelse(batt_delta == 0 & batt_max == 1, "surface", NA)) %>%
  fill(status) %>%
  select(m_present_time, status) %>%
  full_join(yunk) %>%
  arrange(m_present_time) %>%
  fill(status)
  
tunk <- chunk %>%
  filter(m_present_time >= "2022-8-15 10:00:00" & m_present_time < "2022-8-15 14:00:00") %>%
  mutate(osg_theta = theta(osg_salinity, sci_water_temp, sci_water_pressure))

osg_tsplot <- ggplot(
  data = filter(tunk, osg_salinity > 0),
  aes(x=osg_salinity,
      y=osg_theta)) +
  geom_point()
  
ts_plot(filter(tunk, osg_salinity > 0),
        temp_col = "osg_theta",
        sal_col = "osg_salinity",
        #xlim = c(min(chunk$sci_rbrctd_salinity_00, na.rm = TRUE), max(chunk$sci_rbrctd_temperature_00, na.rm = TRUE)),
        #ylim = c(min(chunk$sci_rbrctd_temperature_00, na.rm = TRUE), max(chunk$sci_rbrctd_temperature_00, na.rm = TRUE)),
        zoom = TRUE, 
        #margin_distr = TRUE,
        #xlim = c(32, 37),
)

plotup <- list()
for (i in input){
  plotup[[i]] = ggplot(data = select(chunk, m_present_time, all_of(i)) %>%
                         pivot_longer(
                           cols = !m_present_time,
                           names_to = "variable",
                           values_to = "count") %>%
                         filter(!is.na(count)),
                       aes(x = m_present_time,
                           y = count,
                           color = variable,
                           shape = variable)) +
    geom_point() +
    ylab(i) +
    #coord_cartesian(xlim = rangefli$x, ylim = rangefli$y, expand = FALSE) +
    theme_minimal()
}

wrap_plots(plotup, ncol = 1)
colorvec <- c("red","blue","purple","yellow","green")
aligned_plots <- align_plots(plotup[[1]], plotup[[2]], align="hv", axis="tblr")
ggdraw(aligned_plots[[1]]) + draw_plot(aligned_plots[[2]])

wrap_elements(get_plot_component(plotup[[1]], "ylab-l")) +
  wrap_elements(get_y_axis(plotup[[1]])) +
  wrap_elements(get_plot_component(plotup[[2]], "ylab-1")) +
  wrap_elements(get_y_axis(plotup[[2]])) +
  wrap_l
  plot_layout(widths = c(3, 1, 3, 1, 40))



ggplot(
  data =
    select(chunk, m_present_time, all_of(input)) %>%
    pivot_longer(
      cols = !m_present_time,
      names_to = "variable",
      values_to = "count"
    ) %>%
    filter(!is.na(count)),
  aes(x = m_present_time,
      y = count,
      color = variable)
) +
  geom_point()


test <- system("/echos/dbd2asc.exe -c /echos/cache /echos/tbd/usf-stella-2023-059-1-272.tbd >>", 
               intern = TRUE)
