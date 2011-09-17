ruby crude.rb %1 > %1.cpp
g++ %1.cpp -o %1.exe -Wall
%1.exe
